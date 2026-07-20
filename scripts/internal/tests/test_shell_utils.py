#!/usr/bin/env python3

import subprocess
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[3]
WORD_LIST_UTILS = ROOT_DIR / "scripts" / "utils" / "word_list_utils.sh"
AVB_CONFIG = ROOT_DIR / "scripts" / "internal" / "avb" / "configuration.sh"
AVB_IMAGE_METADATA = ROOT_DIR / "scripts" / "internal" / "avb" / "image_metadata.sh"
HEIMDALL_PACKAGING = ROOT_DIR / "scripts" / "internal" / "packaging" / "heimdall.sh"


def run_bash(body: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", 'source "$1"; shift; eval "$1"', "shell-utils-test", str(WORD_LIST_UTILS), body],
        check=False,
        capture_output=True,
        text=True,
    )


class WordListUtilsTests(unittest.TestCase):
    def test_mutation_and_duplicate_suppression(self) -> None:
        result = run_bash(
            'items="boot vendor"; '
            'APPEND_UNIQUE items boot; '
            'APPEND_UNIQUE items dtbo; '
            'REMOVE_ITEM items vendor; '
            'printf "%s" "$items"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "boot dtbo")

    def test_key_value_lookup_uses_last_value_and_removal_uses_key(self) -> None:
        result = run_bash(
            'items="boot=1 vendor=2 boot=3"; '
            'printf "%s|" "$(GET_KV_VALUE boot "$items")"; '
            'REMOVE_KV_ITEM items boot; '
            'printf "%s" "$items"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "3|vendor=2")


class AvbCommandTests(unittest.TestCase):
    def test_sign_command_preserves_argument_order_and_quoting(self) -> None:
        script = """
source "$1"
source "$2"
source "$3"
RESOLVE_PARTITION_SIGNING_CONFIG() {
    PARTITION_SIGN_HASH_ALGORITHM="sha256"
    PARTITION_SIGN_ROLLBACK_INDEX="7"
    PARTITION_SIGN_ROLLBACK_INDEX_LOCATION="3"
    PARTITION_SIGN_ALGORITHM="SHA256_RSA4096"
    PARTITION_SIGN_KEY_PATH="/keys/avb key.pem"
    PARTITION_SIGN_DO_NOT_USE_AB="true"
    PARTITION_SIGN_EXTRA_ARGS="--salt 'aa bb'"
}
command=()
BUILD_SIGN_IMAGE_CMD command "/tmp/system.img" system hashtree 4096 sign
printf "<%s>\\n" "${command[@]}"
"""
        result = subprocess.run(
            [
                "bash",
                "-c",
                script,
                "avb-command-test",
                str(WORD_LIST_UTILS),
                str(AVB_CONFIG),
                str(AVB_IMAGE_METADATA),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "<add_hashtree_footer>",
                "<--image>",
                "</tmp/system.img>",
                "<--partition_name>",
                "<system>",
                "<--partition_size>",
                "<4096>",
                "<--hash_algorithm>",
                "<sha256>",
                "<--rollback_index>",
                "<7>",
                "<--rollback_index_location>",
                "<3>",
                "<--algorithm>",
                "<SHA256_RSA4096>",
                "<--key>",
                "</keys/avb key.pem>",
                "<--do_not_use_ab>",
                "<--salt>",
                "<aa bb>",
            ],
        )


class HeimdallPackagingTests(unittest.TestCase):
    def run_packaging(self, body: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; shift; TEST_ROOT="$1"; shift; eval "$1"',
                "heimdall-packaging-test",
                str(HEIMDALL_PACKAGING),
                self.temp_dir,
                body,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def setUp(self) -> None:
        import tempfile

        self._temp_dir = tempfile.TemporaryDirectory()
        self.temp_dir = self._temp_dir.name

    def tearDown(self) -> None:
        self._temp_dir.cleanup()

    def test_unsigned_build_does_not_copy_stale_signed_bootloader(self) -> None:
        result = self.run_packaging(
            r'''
mkdir -p "$TEST_ROOT"/{tmp,avb,odin,extra-ap,extra-cp,extra-csc,signed,heimdall,src/prebuilts/extras}
touch "$TEST_ROOT/tmp/boot.img" "$TEST_ROOT/signed/sboot.bin"
printf '#!/bin/sh\n' > "$TEST_ROOT/src/prebuilts/extras/flash_heimdall.sh"
TMP_DIR="$TEST_ROOT/tmp"
TARGET_AVB_IMAGE_PACK_DIR="$TEST_ROOT/avb"
ODIN_AP_DIR="$TEST_ROOT/odin"
ODIN_EXTRA_AP_DIR="$TEST_ROOT/extra-ap"
ODIN_EXTRA_CP_DIR="$TEST_ROOT/extra-cp"
ODIN_EXTRA_CSC_DIR="$TEST_ROOT/extra-csc"
TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR="$TEST_ROOT/signed"
HEIMDALL_DIR="$TEST_ROOT/heimdall"
SRC_DIR="$TEST_ROOT/src"
TARGET_SUPER_PARTITION_SIZE=0
TARGET_ENABLE_CUSTOM_AVB=false
TARGET_ENABLE_SAMSUNG_SIGNING=false
TARGET_SAMSUNG_SIGN_BOOTLOADER=false
LOG() { :; }
LOGE() { printf '%s\n' "$*" >&2; }
BUILD_HEIMDALL_PACKAGE
find "$HEIMDALL_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
'''
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["boot.img", "flash_all.sh"])

    def test_heimdall_only_build_does_not_reuse_stale_odin_super(self) -> None:
        result = self.run_packaging(
            r'''
mkdir -p "$TEST_ROOT"/{tmp,avb,odin,extra-ap,extra-cp,extra-csc,signed,heimdall,src/prebuilts/extras}
touch "$TEST_ROOT/tmp/boot.img"
printf stale > "$TEST_ROOT/odin/super.img"
printf '#!/bin/sh\n' > "$TEST_ROOT/src/prebuilts/extras/flash_heimdall.sh"
TMP_DIR="$TEST_ROOT/tmp"
TARGET_AVB_IMAGE_PACK_DIR="$TEST_ROOT/avb"
ODIN_AP_DIR="$TEST_ROOT/odin"
ODIN_EXTRA_AP_DIR="$TEST_ROOT/extra-ap"
ODIN_EXTRA_CP_DIR="$TEST_ROOT/extra-cp"
ODIN_EXTRA_CSC_DIR="$TEST_ROOT/extra-csc"
TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR="$TEST_ROOT/signed"
HEIMDALL_DIR="$TEST_ROOT/heimdall"
SRC_DIR="$TEST_ROOT/src"
TARGET_SUPER_PARTITION_SIZE=1
TARGET_ENABLE_CUSTOM_AVB=false
TARGET_ENABLE_SAMSUNG_SIGNING=false
TARGET_SAMSUNG_SIGN_BOOTLOADER=false
TARGET_BUILD_ODIN_PACKAGE=false
LOG() { :; }
LOGE() { printf '%s\n' "$*" >&2; }
BUILD_ODIN_SUPER_IMAGE() { printf fresh > "$1"; }
BUILD_HEIMDALL_PACKAGE
cat "$HEIMDALL_DIR/super.img"
'''
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "fresh")


if __name__ == "__main__":
    unittest.main()
