#!/usr/bin/env python3

import subprocess
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[3]
WORD_LIST_UTILS = ROOT_DIR / "scripts" / "utils" / "word_list_utils.sh"
AVB_CONFIG = ROOT_DIR / "scripts" / "internal" / "avb" / "configuration.sh"
AVB_IMAGE_METADATA = ROOT_DIR / "scripts" / "internal" / "avb" / "image_metadata.sh"


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


if __name__ == "__main__":
    unittest.main()
