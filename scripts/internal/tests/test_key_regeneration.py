#!/usr/bin/env python3
"""Exercise coordinated rotation in disposable repositories, never in the checkout."""

import contextlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/samsung_signing"))

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization

from apply_binary_patches import load_patch_rows, write_effective_lk_patch_set
from gen_key import generate_artifacts, write_artifacts
from key_bundle import validate_key_bundle
from regenerate_keys import regenerate, stage_shared_identity
from teegris_ta_signing import ensure_identity, load_identity


def file_bytes(folder):
    return {p.relative_to(folder): p.read_bytes() for p in folder.rglob("*") if p.is_file()}


class BundleValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.keys = Path(self.temporary.name)
        self.artifacts = generate_artifacts(self.keys / "crecker")
        write_artifacts(self.artifacts)

    def test_generated_bundle_matches_and_private_material_is_owner_only(self):
        validate_key_bundle(self.keys)
        for path, (_, mode) in self.artifacts.items():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)

    def test_mismatched_fuse_and_public_pairs_are_rejected(self):
        for name in ("crecker.efuse", "crecker.hmac", "crecker_stage2_tee_pubkey.bin",
                     "crecker_stage2_ree_pubkey.bin", "crecker_stage3_pubkey.bin"):
            with self.subTest(name=name):
                path = self.keys / name
                original = path.read_bytes()
                changed = bytearray(original)
                changed[-1] ^= 1
                path.write_bytes(changed)
                with self.assertRaises(ValueError):
                    validate_key_bundle(self.keys)
                path.write_bytes(original)

    def test_missing_bundle_file_is_rejected(self):
        (self.keys / "crecker.efuse").unlink()
        with self.assertRaises(FileNotFoundError):
            validate_key_bundle(self.keys)

    def test_generation_refuses_to_replace_existing_files(self):
        previous = file_bytes(self.keys)
        with self.assertRaises(FileExistsError):
            write_artifacts(generate_artifacts(self.keys / "crecker"))
        self.assertEqual(file_bytes(self.keys), previous)

    def test_failed_exclusive_write_removes_only_newly_created_files(self):
        new = self.keys / "new"
        new.mkdir()
        artifacts = generate_artifacts(new / "crecker")
        real_open = os.open
        count = 0

        def fail_second(*args, **kwargs):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("simulated disk failure")
            return real_open(*args, **kwargs)

        with patch("gen_key.os.open", side_effect=fail_second), self.assertRaises(OSError):
            write_artifacts(artifacts)
        self.assertEqual(list(new.iterdir()), [])
        validate_key_bundle(self.keys)


class FuseSubstitutionTests(unittest.TestCase):
    def test_all_model_tables_use_selected_fuse_without_changing_other_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            for table in sorted((ROOT / "security/samsung/patches").glob("lk_*_selected_patches.tsv")):
                with self.subTest(table=table.name):
                    original = table.read_bytes()
                    effective = Path(temporary) / table.name
                    fuse = bytes(range(32))
                    write_effective_lk_patch_set(table, effective, fuse)
                    for kvm in (False, True):
                        before, disabled_before = load_patch_rows(table, kvm=kvm)
                        after, disabled_after = load_patch_rows(effective, kvm=kvm)
                        self.assertEqual(disabled_before, disabled_after)
                        self.assertEqual(len(before), len(after))
                        self.assertEqual(sum(row.new_bytes == fuse for row in after), 1)
                        for old, new in zip(before, after):
                            self.assertEqual((old.offset, old.old_bytes, old.function, old.instruction),
                                             (new.offset, new.old_bytes, new.function, new.instruction))
                            if old.function or old.instruction or len(old.new_bytes) != 32:
                                self.assertEqual(old.new_bytes, new.new_bytes)
                    self.assertEqual(table.read_bytes(), original)

    def test_missing_duplicate_or_disabled_fuse_row_is_rejected(self):
        row = "1|0x00|" + "00" * 32 + "|" + "11" * 32 + "||\n"
        with tempfile.TemporaryDirectory() as temporary:
            source, dest = Path(temporary) / "source.tsv", Path(temporary) / "effective.tsv"
            for content in ("", row + row, row.replace("1|", "0|", 1)):
                source.write_text(content)
                with self.assertRaises(ValueError):
                    write_effective_lk_patch_set(source, dest, bytes(32))
                self.assertFalse(dest.exists())


class RegenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.base = Path(cls.temporary.name) / "base"
        cls.keys = cls.base / "security/samsung/exynos9830_crecker"
        cls.keys.mkdir(parents=True)
        write_artifacts(generate_artifacts(cls.keys / "crecker"))
        cls.donor = SimpleNamespace(certificate=(ROOT / "security/samsung/exynos9830_crecker/ta_signing/fkeymaster.der").read_bytes())
        ensure_identity(cls.keys, cls.donor.certificate)
        shared = cls.base / "shared"
        shared.mkdir()
        stage_shared_identity(shared, 2048, "/CN=Test Platform/")
        avb = cls.base / "security/avb"
        avb.mkdir()
        shutil.copy2(shared / "shared_private.pem", avb / "creckerrom_avb_private.pem")
        shutil.copy2(shared / "shared_public.bin", avb / "creckerrom_avb_public.bin")
        shutil.copy2(shared / "platform.pk8", cls.base / "security/creckerrom_platform.pk8")
        shutil.copy2(shared / "platform.x509.pem", cls.base / "security/creckerrom_platform.x509.pem")
        (cls.base / "out/target/example/work_dir").mkdir(parents=True)
        (cls.base / "out/target/example/work_dir/.completed").write_text("old cached build")
        (cls.base / "out/config.sh").write_text('TARGET_PLATFORM="exynos990"\nTARGET_AVB_ALGORITHM="SHA256_RSA2048"\n')
        (cls.base / "out/fw").mkdir()
        (cls.base / "out/fw/keep").write_text("firmware stays cached")
        (cls.base / "target").mkdir()
        (cls.base / "target/config.sh").write_text("source target stays intact")

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory()
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name) / "repo"
        shutil.copytree(self.base, self.root)
        self.keys = self.root / "security/samsung/exynos9830_crecker"
        self.old_keys = file_bytes(self.keys)
        self.old_security = file_bytes(self.root / "security")

    def rotate(self):
        with patch("regenerate_keys.donor_package", return_value=self.donor), contextlib.redirect_stdout(io.StringIO()):
            return regenerate(self.root)

    def test_rotation_updates_all_identities_backs_up_and_invalidates_only_generated_target(self):
        backup = self.rotate()
        validate_key_bundle(self.keys)
        leaf_key, leaf, root_cert = load_identity(self.keys)
        self.assertEqual(leaf_key.public_key().public_numbers(), leaf.public_key().public_numbers())
        for name in ("crecker_private.pem", "crecker.hmac", "crecker.efuse", "crecker_stage2_tee_private.pem",
                     "crecker_stage2_ree_private.pem", "ta_signing/root-private.pem", "ta_signing/root.der",
                     "ta_signing/fkeymaster-private.pem", "ta_signing/fkeymaster.der"):
            self.assertNotEqual((self.keys / name).read_bytes(), self.old_keys[Path(name)], name)
        for name in ("crecker_stage3_private.pem", "crecker_stage3_pubkey.bin"):
            self.assertEqual((self.keys / name).read_bytes(), self.old_keys[Path(name)])
        self.assertNotEqual(root_cert.fingerprint(hashes.SHA256()),
                            x509.load_der_x509_certificate(self.old_keys[Path("ta_signing/root.der")]).fingerprint(hashes.SHA256()))
        manifest = json.loads((backup / "manifest.json").read_text())
        for path, data in self.old_security.items():
            if path.name.startswith("."):
                continue
            self.assertEqual((backup / manifest[str(self.root / "security" / path)]).read_bytes(), data)
        self.assertFalse((self.root / "out/target").exists())
        self.assertFalse((self.root / "out/config.sh").exists())
        self.assertEqual((self.root / "out/fw/keep").read_text(), "firmware stays cached")
        self.assertEqual((self.root / "target/config.sh").read_text(), "source target stays intact")

    def test_generation_failure_keeps_active_keys_config_and_cache(self):
        with patch("regenerate_keys.stage_shared_identity", side_effect=OSError("simulated generation failure")):
            with self.assertRaises(OSError):
                self.rotate()
        self.assertEqual(file_bytes(self.keys), self.old_keys)
        self.assertTrue((self.root / "out/config.sh").is_file())
        self.assertTrue((self.root / "out/target/example/work_dir/.completed").is_file())
        self.assertFalse((self.root / "security/key-backups").exists())

    def test_build_requires_target_selection_after_rotation(self):
        self.rotate()
        environment = os.environ.copy()
        environment.update(SRC_DIR=str(ROOT), OUT_DIR=str(self.root / "out"))
        result = subprocess.run(["bash", str(ROOT / "scripts/make_rom.sh")], env=environment,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Run source ./buildenv.sh", result.stdout + result.stderr)

    def test_installation_failure_restores_old_identity_and_keeps_cache(self):
        from regenerate_keys import atomic_write
        failed = False

        def fail_one_file(path, data, mode):
            nonlocal failed
            if path == self.keys / "crecker_stage2_ree_private.pem" and not failed:
                failed = True
                raise OSError("simulated installation failure")
            return atomic_write(path, data, mode)

        with patch("regenerate_keys.atomic_write", side_effect=fail_one_file), self.assertRaises(OSError):
            self.rotate()
        self.assertTrue(failed)
        self.assertEqual(file_bytes(self.keys), self.old_keys)
        self.assertEqual((self.root / "security/creckerrom_platform.pk8").read_bytes(),
                         self.old_security[Path("creckerrom_platform.pk8")])
        self.assertTrue((self.root / "out/config.sh").is_file())
        self.assertTrue((self.root / "out/target/example/work_dir/.completed").is_file())

    def test_invalid_donor_never_rotates_or_clears_output(self):
        donor = self.root / "invalid.sec3"
        donor.write_bytes(b"invalid donor")
        with self.assertRaises(ValueError):
            regenerate(self.root, donor)
        self.assertEqual(file_bytes(self.root / "security"), self.old_security)
        self.assertTrue((self.root / "out/config.sh").is_file())

    def test_cache_invalidation_failure_restores_all_keys(self):
        original = Path.rename

        def fail_target(path, destination):
            if path == self.root / "out/target":
                raise OSError("simulated target rename failure")
            return original(path, destination)

        with patch.object(Path, "rename", fail_target), self.assertRaises(OSError):
            self.rotate()
        for path, data in self.old_security.items():
            self.assertEqual((self.root / "security" / path).read_bytes(), data)
        self.assertTrue((self.root / "out/config.sh").is_file())
        self.assertTrue((self.root / "out/target/example/work_dir/.completed").is_file())

    def test_config_invalidation_failure_restores_keys_and_target(self):
        original = Path.unlink

        def fail_config(path, *args, **kwargs):
            if path == self.root / "out/config.sh":
                raise OSError("simulated config removal failure")
            return original(path, *args, **kwargs)

        with patch.object(Path, "unlink", fail_config), self.assertRaises(OSError):
            self.rotate()
        for path, data in self.old_security.items():
            self.assertEqual((self.root / "security" / path).read_bytes(), data)
        self.assertTrue((self.root / "out/config.sh").is_file())
        self.assertTrue((self.root / "out/target/example/work_dir/.completed").is_file())

    def test_configured_private_bundle_and_shared_key_aliases_stay_coherent(self):
        config = self.root / "out/config.sh"
        with config.open("a") as stream:
            stream.write('TARGET_SAMSUNG_SIGNING_KEY_DIR="security/samsung/local"\n'
                         'TARGET_PLATFORM_KEY_SOURCE_PEM="security/private/platform.pem"\n'
                         'TARGET_SAMSUNG_AVB_KEY_PATH="security/private/bootloader.pem"\n'
                         'TARGET_AVB_RECOVERY_KEY_PATH="security/private/recovery.pem"\n'
                         'TARGET_AVB_RECOVERY_ALGORITHM="SHA256_RSA2048"\n'
                         'TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH="security/private/vbmeta.bin"\n')
        self.rotate()
        private = self.root / "security/samsung/local"
        validate_key_bundle(private)
        load_identity(private)
        self.assertEqual((private / "crecker_stage3_private.pem").read_bytes(),
                         self.old_keys[Path("crecker_stage3_private.pem")])
        pem = (self.root / "security/avb/creckerrom_avb_private.pem").read_bytes()
        for name in ("platform", "bootloader", "recovery"):
            self.assertEqual((self.root / "security/private" / f"{name}.pem").read_bytes(), pem)
            self.assertTrue((self.root / "security/private" / f"{name}_public.bin").is_file())
        self.assertEqual((self.root / "security/private/vbmeta.bin").read_bytes(),
                         (self.root / "security/avb/creckerrom_avb_public.bin").read_bytes())
        self.assertEqual(file_bytes(self.keys), self.old_keys)

    def test_incompatible_avb_key_sizes_are_rejected_before_rotation(self):
        config = self.root / "out/config.sh"
        original = config.read_text()
        for extra in ('TARGET_AVB_RECOVERY_ALGORITHM="SHA256_RSA4096"\n',
                      'TARGET_AVB_ALGORITHM="SHA256_RSA8192"\n'):
            with self.subTest(extra=extra):
                config.write_text(original + extra)
                with self.assertRaises(ValueError):
                    self.rotate()
                self.assertEqual(file_bytes(self.root / "security"), self.old_security)
                self.assertTrue((self.root / "out/target/example/work_dir/.completed").is_file())

    def test_output_symlink_is_rejected_before_rotation(self):
        target = self.root / "out/target"
        target.rename(self.root / "outside")
        target.symlink_to(self.root / "outside", target_is_directory=True)
        with self.assertRaises(ValueError):
            self.rotate()
        self.assertEqual(file_bytes(self.keys), self.old_keys)
        self.assertTrue((self.root / "outside/example/work_dir/.completed").is_file())

    def test_ci_recovers_missing_shared_pem_without_replacing_platform_identity(self):
        source = self.root / "restored.pem"
        pk8 = self.root / "security/creckerrom_platform.pk8"
        certificate = self.root / "security/creckerrom_platform.x509.pem"
        before = (pk8.read_bytes(), certificate.read_bytes())
        environment = os.environ.copy()
        environment.update(SRC_DIR=str(ROOT), TARGET_ENABLE_CUSTOM_AVB="true", TARGET_AVB_KEY_PATH=str(source),
                           TARGET_PLATFORM_CERT_PK8_PATH=str(pk8), TARGET_PLATFORM_CERT_X509_PATH=str(certificate))
        subprocess.run(["bash", "-c", '''set -e
LOG(){ :; }; LOGW(){ :; }; LOGE(){ echo "$*" >&2; }
_CHECK_NON_EMPTY_PARAM(){ test -n "$2"; }
source "$SRC_DIR/scripts/utils/platform_signing_utils.sh"
ENSURE_SHARED_PLATFORM_SIGNING_CERTS
'''], env=environment, check=True, capture_output=True)
        key = serialization.load_pem_private_key(source.read_bytes(), password=None)
        cert = x509.load_pem_x509_certificate(certificate.read_bytes())
        self.assertEqual(key.public_key().public_numbers(), cert.public_key().public_numbers())
        self.assertEqual((pk8.read_bytes(), certificate.read_bytes()), before)


if __name__ == "__main__":
    unittest.main()
