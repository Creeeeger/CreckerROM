#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

import io
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[3]


class RecoveryImageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="recovery selection ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"
        self.package = self.root / "package"
        self.firmware = self.root / "odin" / "SM-G986B_AUT"
        self.firmware.mkdir(parents=True)
        self.package.mkdir()
        self.twrp = self.root / "twrp.zip"
        with zipfile.ZipFile(self.twrp, "w") as archive:
            archive.writestr("recovery.img", b"TWRP recovery")

    def write_ap(self, entry: str, data: bytes) -> None:
        with tarfile.open(self.firmware / "AP_G986B_test.tar.md5", "w") as archive:
            info = tarfile.TarInfo(entry)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))

    def select(self, recovery_type: str | None = None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            SRC_DIR=str(ROOT_DIR),
            WORK_DIR=str(self.work),
            TMP_DIR=str(self.package),
            ODIN_DIR=str(self.root / "odin"),
            TARGET_FIRMWARE_PATH="SM-G986B_AUT",
            TARGET_FIRMWARE_MODEL="SM-G986B",
            TARGET_RECOVERY_IMAGE_PATH=str(self.twrp),
            DEBUG="false",
        )
        env.pop("TARGET_RECOVERY_TYPE", None)
        if recovery_type is not None:
            env["TARGET_RECOVERY_TYPE"] = recovery_type
        return subprocess.run(
            ["bash", "-ec", '''
source "$SRC_DIR/scripts/utils/firmware_utils.sh"
source "$SRC_DIR/scripts/internal/packaging/samsung_signing.sh"
source "$SRC_DIR/scripts/internal/packaging/image_inputs.sh"
COPY_TARGET_RECOVERY_IMAGE_TO_TMP
'''],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_recovery(self, expected: bytes) -> None:
        self.assertEqual((self.work / "kernel/recovery.img").read_bytes(), expected)
        self.assertEqual((self.package / "recovery.img").read_bytes(), expected)

    def test_default_and_stock_switch_replace_previous_recovery(self) -> None:
        self.write_ap("recovery.img", b"stock recovery")
        for mode, expected in (
            (None, b"TWRP recovery"),
            ("stock", b"stock recovery"),
            (None, b"TWRP recovery"),
        ):
            with self.subTest(mode=mode):
                result = self.select(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_recovery(expected)

    @unittest.skipUnless(shutil.which("lz4"), "lz4 is required for compressed firmware")
    def test_stock_lz4_does_not_require_twrp(self) -> None:
        compressed = subprocess.run(
            ["lz4", "-z", "-c", "-"], input=b"compressed stock recovery",
            capture_output=True, check=True,
        ).stdout
        self.write_ap("recovery.img.lz4", compressed)
        self.twrp.unlink()
        result = self.select("stock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_recovery(b"compressed stock recovery")

    def test_stock_missing_archive_does_not_fall_back_to_twrp(self) -> None:
        result = self.select("stock")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Stock recovery requires the target AP", result.stderr)
        self.assertFalse((self.package / "recovery.img").exists())

    def test_stock_missing_member_does_not_fall_back_to_twrp(self) -> None:
        self.write_ap("boot.img", b"stock boot")
        result = self.select("stock")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not extract stock recovery.img", result.stderr)

    def test_stock_empty_image_is_rejected(self) -> None:
        self.write_ap("recovery.img", b"")
        result = self.select("stock")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Selected recovery image is empty", result.stderr)

    def test_invalid_recovery_type_is_rejected(self) -> None:
        result = self.select("other")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TARGET_RECOVERY_TYPE must be twrp or stock", result.stderr)


class RecoveryFlagTests(unittest.TestCase):
    def test_buildenv_generates_stock_and_resets_to_twrp_on_next_source(self) -> None:
        # Real configuration generation runs in a temporary out directory.
        # No ROM build or firmware download is invoked.
        with tempfile.TemporaryDirectory(prefix="recovery flags ") as directory:
            root = Path(directory)
            for name in ("scripts", "target", "unica", "security", "prebuilts"):
                (root / name).symlink_to(ROOT_DIR / name, target_is_directory=True)
            shutil.copy2(ROOT_DIR / "buildenv.sh", root / "buildenv.sh")
            env = os.environ.copy()
            env["SRC_DIR"] = str(root)
            result = subprocess.run(
                ["bash", "-ec", '''
source ./buildenv.sh --stock --avb --avb-model G986B y2s > /dev/null
printf 'selected=%s\n' "$TARGET_RECOVERY_TYPE"
source ./buildenv.sh y2s > /dev/null
printf 'selected=%s\n' "$TARGET_RECOVERY_TYPE"
'''], cwd=root, env=env, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["selected=stock", "selected=twrp"])

    def test_build_all_forwards_stock_to_every_target(self) -> None:
        # The build entry point is replaced with a no-op. Only arguments run.
        with tempfile.TemporaryDirectory(prefix="recovery build-all ") as directory:
            root = Path(directory)
            shutil.copy2(ROOT_DIR / "build_all_s20_n20.sh", root / "build_all_s20_n20.sh")
            (root / "buildenv.sh").write_text('printf "%s\\n" "$*" >> args.log\n')
            (root / "scripts").mkdir()
            noop = root / "scripts/make_rom.sh"
            noop.write_text("#!/usr/bin/env bash\nexit 0\n")
            noop.chmod(0o755)
            for flags, stock in (([], False), (["--stock"], True)):
                with self.subTest(flags=flags):
                    result = subprocess.run(
                        ["bash", "build_all_s20_n20.sh", *flags], cwd=root,
                        capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    lines = (root / "args.log").read_text().splitlines()
                    self.assertEqual(len(lines), 10)
                    self.assertTrue(all(("--stock" in line.split()) == stock for line in lines))
                    (root / "args.log").unlink()
            for flag, status in (("--help", 0), ("--invalid", 1)):
                result = subprocess.run(
                    ["bash", "build_all_s20_n20.sh", flag], cwd=root,
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn("Usage:", result.stderr)
                self.assertFalse((root / "args.log").exists())


if __name__ == "__main__":
    unittest.main()
