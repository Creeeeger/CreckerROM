#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
from pathlib import Path

INTERNAL_DIR = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rollback_super = load_module("rollback_super", INTERNAL_DIR / "rollback_super.py")


class RollbackSuperTests(unittest.TestCase):
    def test_normalize_and_build_preserve_layout(self):
        raw = {
            "super_device": {"name": "super"},
            "block_devices": [
                {
                    "name": "super",
                    "size": 16384,
                    "block_size": 4096,
                    "alignment": 4096,
                    "alignment_offset": 0,
                }
            ],
            "groups": [{"name": "main", "maximum_size": 8192}],
            "partitions": [
                {"name": "system", "group_name": "main", "size": 4},
                {"name": "vendor", "group_name": "main", "size": 3},
            ],
        }
        metadata = """Metadata max size: 65536 bytes
Metadata slot count: 2
Header flags: virtual_ab_device
Partition table:
------------------------
  Name: system
  Attributes: readonly
  Name: vendor
  Attributes: none
Super partition layout:
"""

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "super.raw"
            source.write_bytes(b"source")
            images = root / "images"
            images.mkdir()
            (images / "system.img").write_bytes(b"sys1")
            (images / "vendor.img").write_bytes(b"ven")

            layout = rollback_super.normalize_layout(raw, metadata, source)
            command = rollback_super.build_command(
                layout, images, root / "super.sparse", Path("lpmake")
            )

        self.assertEqual(layout["metadata_size"], 65536)
        self.assertEqual(layout["metadata_slots"], 2)
        self.assertIn("--virtual-ab", command)
        self.assertIn("system:readonly:4:main", command)
        self.assertIn("vendor:none:3:main", command)
        self.assertIn("super:16384:4096:0", command)

    def test_build_rejects_changed_partition_size(self):
        layout = {
            "metadata_size": 65536,
            "metadata_slots": 2,
            "super_name": "super",
            "header_flags": "none",
            "block_devices": [{"name": "super", "size": 16384}],
            "groups": [{"name": "main", "maximum_size": 8192}],
            "partitions": [
                {
                    "name": "system",
                    "attributes": "readonly",
                    "size": 4,
                    "group": "main",
                }
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "system.img").write_bytes(b"wrong")
            with self.assertRaisesRegex(ValueError, "size changed"):
                rollback_super.build_command(
                    layout, root, root / "super.sparse", Path("lpmake")
                )


if __name__ == "__main__":
    unittest.main()
