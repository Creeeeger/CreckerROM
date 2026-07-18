#!/usr/bin/env python3

import subprocess
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[3]
METADATA_SCRIPT = ROOT_DIR / "scripts" / "samsung_signing" / "bl1_model_metadata.sh"

EXPECTED = {
    "G780F": ("0x154", "11", "24"),
    "G980F": ("0x143", "11", "23"),
    "G981B": ("0x13D", "11", "23"),
    "G985F": ("0x142", "11", "23"),
    "G986B": ("0x13C", "11", "23"),
    "G988B": ("0x13E", "11", "23"),
    "N980F": ("0x153", "11", "18"),
    "N981B": ("0x14E", "11", "18"),
    "N985F": ("0x152", "11", "18"),
    "N986B": ("0x14D", "11", "18"),
}


def run_metadata(function: str, model: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; "$2" "$3"',
            "metadata-test",
            str(METADATA_SCRIPT),
            function,
            model,
        ],
        check=False,
        capture_output=True,
        text=True,
    )


class SamsungModelMetadataTest(unittest.TestCase):
    def test_supported_models_and_metadata(self) -> None:
        supported = run_metadata("PRINT_SAMSUNG_BL1_SUPPORTED_MODELS")
        self.assertEqual(supported.returncode, 0, supported.stderr)
        self.assertEqual(set(supported.stdout.split()), set(EXPECTED))

        for model, expected in EXPECTED.items():
            with self.subTest(model=model):
                result = run_metadata("GET_SAMSUNG_BL1_MODEL_METADATA", model.lower())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(tuple(result.stdout.split()), expected)

    def test_unknown_model_is_rejected(self) -> None:
        result = run_metadata("GET_SAMSUNG_BL1_MODEL_METADATA", "UNKNOWN")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
