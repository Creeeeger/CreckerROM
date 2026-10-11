#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Regenerate or restore ROM signing identities, then discard generated target state."""

import argparse
import fcntl
import json
import os
import re
import shlex
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from avb_cli import avb_environment
from gen_key import generate_artifacts, write_artifacts
from key_bundle import KEY_FILENAMES, public_blob, validate_key_bundle
from teegris_elf import sha256
from teegris_ta_signing import SOURCE_TA_SHA256, ensure_identity, load_identity, parse_package

REPO_DIR = Path(__file__).resolve().parents[2]
AVBTOOL = REPO_DIR / "external/android-tools/vendor/avb/avbtool.py"
STAGE3_FILES = ("crecker_stage3_private.pem", "crecker_stage3_pubkey.bin")
TA_FILES = ("root-private.pem", "root.der", "fkeymaster-private.pem", "fkeymaster.der")


def read_config(path: Path) -> dict[str, str]:
    """Read literal assignments emitted by gen_config_file; do not execute them."""
    values = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            if not re.match(r"^(?:TARGET_|SOURCE_)[A-Z0-9_]+=", line):
                continue
            name, value = line.split("=", 1)
            words = shlex.split(value)
            if len(words) != 1:
                raise ValueError(f"Expected a literal assignment for {name} in {path}")
            values[name] = words[0]
    return values


def configured_path(root: Path, config: dict[str, str], name: str, default: Path) -> Path:
    value = config.get(name, "")
    path = Path(value).expanduser() if value not in ("", "none") else default
    return (path if path.is_absolute() else root / path).resolve()


def public_key_path(private: Path) -> Path:
    name = str(private)
    if name.endswith("_private.pem"):
        return Path(name[:-len("_private.pem")] + "_public.bin")
    if name.endswith(".pem"):
        return Path(name[:-4] + "_public.bin")
    return Path(name + ".public.bin")


def signing_paths(root: Path, config: dict[str, str]):
    keys = configured_path(root, config, "TARGET_SAMSUNG_SIGNING_KEY_DIR",
                           root / "security/samsung/exynos9830_crecker")
    avb = configured_path(root, config, "TARGET_AVB_KEY_PATH", root / "security/avb/creckerrom_avb_private.pem")
    partition_key_names = sorted(name for name in config if re.fullmatch(r"TARGET_AVB_.+_KEY_PATH", name))
    sources = tuple(dict.fromkeys((avb,
        configured_path(root, config, "TARGET_SAMSUNG_AVB_KEY_PATH", avb),
        configured_path(root, config, "TARGET_PLATFORM_KEY_SOURCE_PEM", avb),
        *(configured_path(root, config, name, avb) for name in partition_key_names))))
    public_outputs = set(public_key_path(path) for path in sources)
    if config.get("TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH", "none") not in ("", "none"):
        public_outputs.add(configured_path(root, config, "TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH", avb))
    pk8 = configured_path(root, config, "TARGET_PLATFORM_CERT_PK8_PATH", root / "security/creckerrom_platform.pk8")
    cert = configured_path(root, config, "TARGET_PLATFORM_CERT_X509_PATH", root / "security/creckerrom_platform.x509.pem")
    return keys, sources, pk8, cert, public_outputs


def create_backup(root: Path, config: dict[str, str], suffix: str = "") -> Path:
    folder = root / "security/key-backups"
    folder.mkdir(mode=0o700, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + suffix, dir=folder))
    settings = {"root": str(root), "config": config}
    atomic_write(backup / "key_config.json", json.dumps(settings, indent=2).encode(), 0o600)
    return backup


def donor_package(root: Path, config: dict[str, str], donor: Path | None):
    if donor is not None:
        candidates = [donor]
    else:
        candidates = []
        source = config.get("SOURCE_FIRMWARE", "").split("/")
        if len(source) >= 2:
            candidates.append(root / "out/fw" / f"{source[0]}_{source[1]}" /
                              "vendor/tee/00000000-0000-0000-0000-4662436b6d52")
        candidates.extend(sorted((root / "out/fw").glob(
            "*/vendor/tee/00000000-0000-0000-0000-4662436b6d52")))
    for path in candidates:
        if path.is_file():
            data = path.read_bytes()
            if sha256(data) == SOURCE_TA_SHA256:
                return parse_package(data)
    raise ValueError("Pinned S721B FKeyMaster donor missing or changed. Extract the source firmware "
                     "first, or pass --donor /path/to/the/pristine/FKeyMaster/container.")


def stage_shared_identity(staging: Path, bits: int, subject: str) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=bits)
    pem = staging / "shared_private.pem"
    pem.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()))
    pem.chmod(0o600)
    environment = avb_environment()
    environment.update(SRC_DIR=str(REPO_DIR), TARGET_ENABLE_CUSTOM_AVB="true",
                       TARGET_AVB_KEY_PATH=str(pem), TARGET_PLATFORM_CERT_SUBJECT=subject,
                       TARGET_PLATFORM_CERT_X509_PATH=str(staging / "platform.x509.pem"),
                       TARGET_PLATFORM_CERT_PK8_PATH=str(staging / "platform.pk8"))
    script = '''set -e
LOG(){ :; }; LOGW(){ :; }; LOGE(){ echo "$*" >&2; }
_CHECK_NON_EMPTY_PARAM(){ test -n "$2"; }
source "$SRC_DIR/scripts/utils/platform_signing_utils.sh"
ENSURE_SHARED_PLATFORM_SIGNING_CERTS
'''
    subprocess.run(["bash", "-c", script], env=environment, check=True, capture_output=True, text=True)
    subprocess.run([sys.executable, str(AVBTOOL), "extract_public_key", "--key", str(pem),
                    "--output", str(staging / "shared_public.bin")], env=environment, check=True,
                   capture_output=True, text=True)
    validate_shared_identity(pem, staging / "platform.pk8", staging / "platform.x509.pem",
                             staging / "shared_public.bin")


def validate_shared_identity(pem: Path, pk8: Path, certificate: Path, public_blob_path: Path) -> None:
    key = serialization.load_pem_private_key(pem.read_bytes(), password=None)
    android_key = serialization.load_der_private_key(pk8.read_bytes(), password=None)
    cert = x509.load_pem_x509_certificate(certificate.read_bytes())
    if not isinstance(key, rsa.RSAPrivateKey) or not isinstance(android_key, rsa.RSAPrivateKey):
        raise ValueError("Shared AVB/platform identity requires RSA")
    public = key.public_key()
    numbers = public.public_numbers()
    if android_key.public_key().public_numbers() != numbers or cert.public_key().public_numbers() != numbers:
        raise ValueError("AVB PEM, platform PK8 and certificate do not match")
    public.verify(cert.signature, cert.tbs_certificate_bytes, padding.PKCS1v15(), hashes.SHA256())
    blob = public_blob_path.read_bytes()
    bits, inverse = struct.unpack_from(">II", blob)
    size = bits // 8
    if bits != key.key_size or len(blob) != 8 + 2 * size or numbers.e != 65537:
        raise ValueError("AVB public blob size/exponent mismatch")
    if (int.from_bytes(blob[8:8 + size], "big") != numbers.n
            or int.from_bytes(blob[8 + size:], "big") != pow(2, 2 * bits, numbers.n)
            or inverse != -pow(numbers.n, -1, 2**32) % 2**32):
        raise ValueError("AVB public blob differs from the shared RSA key")


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".key-regen-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def install_files(artifacts: dict[Path, tuple[bytes | None, int]], backup: Path,
                  preserved: tuple[Path, ...], verify) -> None:
    previous = {}
    manifest = {}
    for index, path in enumerate(dict.fromkeys((*artifacts, *preserved))):
        if path.exists():
            if not path.is_file():
                raise ValueError(f"Expected a key/config file: {path}")
            data, mode = path.read_bytes(), stat.S_IMODE(path.stat().st_mode)
            previous[path] = (data, mode)
            name = f"{index:02d}-{path.name}"
            atomic_write(backup / name, data, 0o600)
            manifest[str(path)] = name
        else:
            previous[path] = None
            manifest[str(path)] = None
    atomic_write(backup / "manifest.json", json.dumps(manifest, indent=2).encode(), 0o600)
    installed = []
    try:
        for path, (data, mode) in artifacts.items():
            if data is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, data, mode)
            installed.append(path)
        verify()
    except BaseException:
        for path in reversed(installed):
            original = previous[path]
            if original is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, *original)
        raise


def clear_generated_target(root: Path) -> None:
    target = root / "out/target"
    retired = None
    if target.exists():
        retired = Path(tempfile.mkdtemp(prefix=".target-before-key-regen-", dir=root / "out"))
        retired.rmdir()
        target.rename(retired)
    try:
        (root / "out/config.sh").unlink(missing_ok=True)
    except OSError:
        if retired is not None:
            retired.rename(target)
        raise
    if retired is not None:
        try:
            shutil.rmtree(retired)
        except OSError as error:
            # Moving the directory already invalidated every cached target.
            print(f"Old target output is inactive but could not be removed: {retired}: {error}", file=sys.stderr)


def regenerate(root: Path = REPO_DIR, donor: Path | None = None) -> Path:
    root = root.resolve()
    config = read_config(root / "out/config.sh")
    if config.get("TARGET_PLATFORM", "exynos990") != "exynos990":
        raise ValueError("Unified Samsung key regeneration is for Exynos990 targets")
    soc = config.get("TARGET_SAMSUNG_SIGNING_SOC", "exynos990")
    keys, sources, pk8, cert, public_outputs = signing_paths(root, config)
    algorithm = config.get("TARGET_AVB_ALGORITHM", "SHA256_RSA4096")
    match = re.fullmatch(r"SHA(?:256|512)_RSA(2048|4096|8192)", algorithm)
    algorithms = [config.get("TARGET_SAMSUNG_AVB_ALGORITHM", algorithm)]
    algorithms += [value for name, value in config.items()
                   if re.fullmatch(r"TARGET_AVB_.+_ALGORITHM", name) and not name.endswith("_HASH_ALGORITHM")
                   and value not in ("", "none")]
    if match is None or any(re.fullmatch(r"SHA(?:256|512)_RSA" + match[1], value) is None for value in algorithms):
        raise ValueError("Shared AVB/platform keys require matching configured RSA sizes")
    if int(match[1]) > 4096:
        raise ValueError("Exynos990 keystorage supports shared RSA keys up to 4096 bits")
    package = donor_package(root, config, donor)
    stage3_source = keys
    if not any((keys / name).exists() for name in STAGE3_FILES):
        stage3_source = root / "security/samsung/exynos9830_crecker"
    stage3 = {name: (stage3_source / name).read_bytes() for name in STAGE3_FILES}
    if public_blob(stage3_source / STAGE3_FILES[0], soc) != stage3[STAGE3_FILES[1]]:
        raise ValueError("Existing Stage3 key pair does not match; it will not be regenerated")

    # Only generated output can be cleared. Never follow an output symlink.
    for path in (root / "out", root / "out/target", root / "out/config.sh"):
        if path.is_symlink():
            raise ValueError(f"Refusing generated output symlink: {path}")
    destinations = [keys / name for name in (
        "crecker_private.pem", "crecker.hmac", "crecker.efuse", "crecker_stage2_tee_private.pem",
        "crecker_stage2_tee_pubkey.bin", "crecker_stage2_ree_private.pem", "crecker_stage2_ree_pubkey.bin")]
    destinations += [keys / "ta_signing" / name for name in TA_FILES]
    destinations += [pk8, cert, *sources, *public_outputs]
    destinations_with_stage3 = destinations + [keys / name for name in STAGE3_FILES]
    if len(destinations_with_stage3) != len(set(destinations_with_stage3)):
        raise ValueError("Signing output paths overlap")
    for path in (*destinations, keys / STAGE3_FILES[0], keys / STAGE3_FILES[1]):
        if root / "out/target" in path.parents or path == root / "out/config.sh":
            raise ValueError(f"Signing key path lies inside generated target state: {path}")

    (root / "security").mkdir(parents=True, exist_ok=True)
    descriptor = os.open(root / "security/.key-regeneration.lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix="crecker-key-regen-") as temporary:
            staging = Path(temporary)
            staged_keys = staging / "samsung"
            staged_keys.mkdir(mode=0o700)
            write_artifacts(generate_artifacts(staged_keys / "crecker", soc, ("stage2_tee", "stage2_ree")))
            for name, data in stage3.items():
                atomic_write(staged_keys / name, data, 0o600 if name.endswith(".pem") else 0o644)
            validate_key_bundle(staged_keys, soc)
            ensure_identity(staged_keys, package.certificate)
            stage_shared_identity(staging, int(match[1]), config.get("TARGET_PLATFORM_CERT_SUBJECT", "/CN=CreckerROM Platform/"))
            print("Generated and validated BL1/Stage2, shared AVB/platform and FKeyMaster identities.")

            artifacts = {}
            for path in staged_keys.iterdir():
                if path.is_file() and not path.name.startswith(".") and path.name not in STAGE3_FILES:
                    artifacts[keys / path.name] = (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
            # Preserve Stage3 in place, or copy the existing default pair into a new private bundle.
            if stage3_source != keys:
                for name, data in stage3.items():
                    artifacts[keys / name] = (data, 0o600 if name.endswith(".pem") else 0o644)
            for name in TA_FILES:
                artifacts[keys / "ta_signing" / name] = (
                    (staged_keys / "ta_signing" / name).read_bytes(), 0o600 if name.endswith(".pem") else 0o644)
            for path in sources:
                artifacts[path] = ((staging / "shared_private.pem").read_bytes(), 0o600)
            for path in sorted(public_outputs):
                artifacts[path] = ((staging / "shared_public.bin").read_bytes(), 0o644)
            artifacts[pk8] = ((staging / "platform.pk8").read_bytes(), 0o600)
            artifacts[cert] = ((staging / "platform.x509.pem").read_bytes(), 0o644)
            backup = create_backup(root, config)

            def verify():
                validate_key_bundle(keys, soc)
                load_identity(keys)
                for source in sources:
                    validate_shared_identity(source, pk8, cert, public_key_path(source))
                if any(path.read_bytes() != (staging / "shared_public.bin").read_bytes() for path in public_outputs):
                    raise ValueError("An AVB public-key output differs from the shared RSA key")
                clear_generated_target(root)

            install_files(artifacts, backup, tuple(stage3_source / name for name in STAGE3_FILES)
                          + (root / "out/config.sh",), verify)
    print(f"Previous keys backed up in {backup}")
    print("Cleared out/target and out/config.sh. Run source ./buildenv.sh [options] <target> again, then m.")
    return backup


def choose_backup(root: Path) -> Path | None:
    folder = root / "security/key-backups"
    backups = sorted((path for path in folder.glob("*") if path.is_dir() and not path.is_symlink()
                      and (path / "manifest.json").is_file()), reverse=True)
    if not backups:
        raise ValueError(f"No key backups found in {folder}")
    print("Available key backups (newest first):")
    for number, path in enumerate(backups, 1):
        print(f"  {number}) {path}")
    while True:
        try:
            answer = input("Enter the backup number to restore (0 to cancel): ").strip()
        except EOFError:
            return None
        if answer == "0":
            return None
        if answer.isdecimal() and 1 <= int(answer) <= len(backups):
            return backups[int(answer) - 1]
        print(f"Enter a number from 1 to {len(backups)}, or 0 to cancel.")


def backup_config(root: Path, backup: Path, manifest: dict) -> dict[str, str]:
    settings_path = backup / "key_config.json"
    if settings_path.is_symlink():
        raise ValueError("Refusing a key backup configuration symlink")
    if settings_path.is_file():
        settings = json.loads(settings_path.read_text())
        if not isinstance(settings, dict) or settings.get("root") != str(root):
            raise ValueError("This key backup belongs to a different repository path")
        config = settings.get("config")
        if not isinstance(config, dict) or any(not isinstance(k, str) or not isinstance(v, str)
                                               for k, v in config.items()):
            raise ValueError("Invalid key backup configuration")
        return config
    # Existing backups predate key_config.json. Their saved config identifies aliases.
    name = manifest.get(str(root / "out/config.sh"))
    return read_config(backup / name) if name is not None else {}


def prepare_restore(root: Path, backup: Path):
    if (backup / "manifest.json").is_symlink():
        raise ValueError("Refusing a key backup manifest symlink")
    manifest = json.loads((backup / "manifest.json").read_text())
    if not isinstance(manifest, dict):
        raise ValueError("Invalid key backup manifest")
    for path, name in manifest.items():
        if not Path(path).is_absolute() or (name is not None and (
                not isinstance(name, str) or Path(name).name != name
                or (backup / name).is_symlink() or not (backup / name).is_file())):
            raise ValueError(f"Invalid or missing key backup entry: {path}")
    config = backup_config(root, backup, manifest)
    keys, sources, pk8, cert, public_outputs = signing_paths(root, config)
    expected = {keys / name for name in KEY_FILENAMES.values()}
    expected.update(keys / "ta_signing" / name for name in TA_FILES)
    expected.update((*sources, pk8, cert, *public_outputs))
    if not expected <= {Path(path) for path in manifest}:
        raise ValueError("Backup is incomplete for its configured signing identities")
    allowed = expected | {root / "out/config.sh"}
    allowed.update(root / "security/samsung/exynos9830_crecker" / name for name in STAGE3_FILES)
    if any(Path(path) not in allowed for path in manifest):
        raise ValueError("Backup contains paths outside its signing key configuration")
    for path in (root / "out", root / "out/target", root / "out/config.sh"):
        if path.is_symlink():
            raise ValueError(f"Refusing generated output symlink: {path}")
    artifacts = {}
    for original, name in manifest.items():
        path = Path(original)
        if path == root / "out/config.sh":
            continue
        if path.is_symlink() or path.is_relative_to(root / "out/target"):
            raise ValueError(f"Refusing unsafe key restoration path: {path}")
        private = path in (*sources, pk8) or path.name.endswith("private.pem") or path.name in ("crecker.hmac", "crecker.efuse")
        mode = 0o600 if private else 0o644
        artifacts[path] = ((backup / name).read_bytes() if name is not None else None, mode)
    return artifacts, config


def validate_restore(artifacts, root: Path, config: dict[str, str]) -> None:
    keys, sources, pk8, cert, public_outputs = signing_paths(root, config)
    with tempfile.TemporaryDirectory(prefix="crecker-key-restore-") as temporary:
        staging = Path(temporary)
        staged_keys = staging / "samsung"
        staged_keys.mkdir()
        for name in (*KEY_FILENAMES.values(), *("ta_signing/" + name for name in TA_FILES)):
            data = artifacts[keys / name][0]
            if data is not None:
                atomic_write(staged_keys / name, data, 0o600)
        boot_present = [(staged_keys / name).exists() for name in KEY_FILENAMES.values()]
        if any(boot_present):
            validate_key_bundle(staged_keys, config.get("TARGET_SAMSUNG_SIGNING_SOC", "exynos990"))
        elif keys == root / "security/samsung/exynos9830_crecker":
            raise ValueError("Backup is missing the original default Samsung signing bundle")
        if any((staged_keys / "ta_signing" / name).exists() for name in TA_FILES):
            load_identity(staged_keys)
        default_keys = root / "security/samsung/exynos9830_crecker"
        if not any(boot_present) and not all(default_keys / name in artifacts for name in STAGE3_FILES):
            raise ValueError("Backup is missing the original Samsung signing bundle and preserved Stage3 pair")
        if default_keys != keys and any(default_keys / name in artifacts for name in STAGE3_FILES):
            for name in STAGE3_FILES:
                data = artifacts.get(default_keys / name, (None, 0))[0]
                if data is None:
                    raise ValueError("Backup has an incomplete preserved Stage3 pair")
                atomic_write(staging / name, data, 0o600)
            if public_blob(staging / STAGE3_FILES[0], config.get("TARGET_SAMSUNG_SIGNING_SOC", "exynos990")) != (staging / STAGE3_FILES[1]).read_bytes():
                raise ValueError("Backup preserved Stage3 pair does not match")
        pem_data = [artifacts[path][0] for path in sources if artifacts[path][0] is not None]
        pk8_data, cert_data = artifacts[pk8][0], artifacts[cert][0]
        if not pem_data and pk8_data is not None:
            key = serialization.load_der_private_key(pk8_data, password=None)
            pem_data = [key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption())]
        if pem_data or cert_data is not None or any(artifacts[path][0] is not None for path in public_outputs):
            if not pem_data or pk8_data is None or cert_data is None:
                raise ValueError("Backup has an incomplete shared AVB/platform identity")
            pem, staged_pk8, staged_cert, public = (staging / name for name in ("shared.pem", "platform.pk8", "platform.x509.pem", "public.bin"))
            atomic_write(pem, pem_data[0], 0o600)
            atomic_write(staged_pk8, pk8_data, 0o600)
            atomic_write(staged_cert, cert_data, 0o600)
            subprocess.run([sys.executable, str(AVBTOOL), "extract_public_key", "--key", str(pem),
                            "--output", str(public)], env=avb_environment(), check=True, capture_output=True)
            expected_public = public.read_bytes()
            for data in pem_data:
                atomic_write(pem, data, 0o600)
                validate_shared_identity(pem, staged_pk8, staged_cert, public)
            if any(artifacts[path][0] not in (None, expected_public) for path in public_outputs):
                raise ValueError("Backup AVB public blobs differ from its shared RSA key")


def restore_backup(root: Path, backup: Path) -> Path:
    root, backup = root.resolve(), backup.resolve()
    if backup.parent != root / "security/key-backups":
        raise ValueError("Select a backup from this repository's security/key-backups directory")
    descriptor = os.open(root / "security/.key-regeneration.lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        artifacts, config = prepare_restore(root, backup)
        validate_restore(artifacts, root, config)
        undo = create_backup(root, config, "before-restore-")

        def verify():
            for path, (data, _) in artifacts.items():
                if data is None:
                    if path.exists():
                        raise ValueError(f"Restoration did not remove newly created file: {path}")
                elif path.read_bytes() != data:
                    raise ValueError(f"Restored file differs from its backup: {path}")
            clear_generated_target(root)

        install_files(artifacts, undo, (root / "out/config.sh",), verify)
    print(f"Restored and validated keys from {backup}")
    print(f"Previous keys backed up in {undo}")
    print("Cleared out/target and out/config.sh. Run source ./buildenv.sh [options] <target> again, then m.")
    return undo


def main(argv=None, root: Path = REPO_DIR):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--donor", type=Path, help="Pristine pinned S721B FKeyMaster SEC3 container; otherwise locate it in out/fw")
    mode.add_argument("--restore", action="store_true", help="List backup folders and restore keys by backup number")
    args = parser.parse_args(argv)
    try:
        if args.restore:
            backup = choose_backup(root)
            if backup is None:
                print("Key restoration cancelled.")
                return
            restore_backup(root, backup)
        else:
            regenerate(root, donor=args.donor)
    except (OSError, ValueError, subprocess.CalledProcessError, InvalidSignature) as error:
        detail = str(error) or "Signature verification failed"
        parser.exit(1, f"Key {'restoration' if args.restore else 'regeneration'} failed: {detail}\n")
    except KeyboardInterrupt:
        parser.exit(130, "\nKey operation cancelled.\n")


if __name__ == "__main__":
    main()
