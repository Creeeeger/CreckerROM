#!/usr/bin/env python3

import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[3]
SIGNING_DIR = ROOT_DIR / "scripts" / "samsung_signing"
sys.path.insert(0, str(SIGNING_DIR))


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SIGNING_DIR / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class AesBackendCharacterizationTests(unittest.TestCase):
    def test_existing_tools_produce_the_same_known_ciphertext(self) -> None:
        recrypt_epbl = load_module("recrypt_epbl_test", "recrypt-epbl.py")
        tzsw_crypt = load_module("tzsw_crypt_test", "tzsw_crypt_tool.py")
        plaintext = bytes(range(32))
        key = bytes(range(32))
        iv = bytes(range(16))
        expected = bytes.fromhex(
            "f29000b62a499fd0a9f39a6add2e7780"
            "9543b86fc046fa883a9446b82e47d12d"
        )

        _, recrypt_aes = recrypt_epbl.select_aes_backend()
        self.assertEqual(recrypt_aes(plaintext, key, iv, False), expected)
        self.assertEqual(tzsw_crypt.aes_cbc(plaintext, key, iv, False), expected)
        self.assertEqual(tzsw_crypt.aes_cbc(expected, key, iv, True), plaintext)


class SparseImageTests(unittest.TestCase):
    def test_reads_ranges_across_raw_and_dont_care_chunks(self) -> None:
        sparse_image = load_module("sparse_image_test", "sparse_image.py")
        block_size = 4096
        raw_block = bytes((index % 251 for index in range(block_size)))
        header = struct.pack(
            "<IHHHHIIII",
            sparse_image.SPARSE_MAGIC,
            1,
            0,
            28,
            12,
            block_size,
            2,
            2,
            0,
        )
        raw_chunk = struct.pack(
            "<HHII",
            sparse_image.SPARSE_RAW_CHUNK,
            0,
            1,
            12 + block_size,
        )
        empty_chunk = struct.pack(
            "<HHII",
            sparse_image.SPARSE_DONT_CARE_CHUNK,
            0,
            1,
            12,
        )

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "super.img"
            path.write_bytes(header + raw_chunk + raw_block + empty_chunk)
            parsed = sparse_image.read_sparse_header(path)
            output = sparse_image.read_sparse_range(
                path,
                block_size - 8,
                16,
                parsed,
            )

        self.assertEqual(parsed.output_size, block_size * 2)
        self.assertEqual(output, raw_block[-8:] + b"\x00" * 8)


class BinaryIoTests(unittest.TestCase):
    def test_little_endian_helpers_and_ascii_names(self) -> None:
        binary_io = load_module("binary_io_test", "binary_io.py")
        self.assertEqual(binary_io.write_u32(0x78563412), b"\x12\x34\x56\x78")
        self.assertEqual(binary_io.read_u32(b"xx\x12\x34\x56\x78", 2), 0x78563412)
        self.assertEqual(binary_io.ascii_name(b"vbmeta\x00ignored"), "vbmeta")


class BinaryPatchProfileTests(unittest.TestCase):
    def test_kvm_and_rollback_profiles_are_independent(self) -> None:
        binary_patches = load_module(
            "apply_binary_patches_test",
            "apply_binary_patches.py",
        )
        table = """# profile test
1|0x00|00|01|always|always
kvm|0x01|00|01|kvm|kvm
rollback|0x02|00|01|rollback|rollback
0|0x03|00|01|disabled|disabled
"""

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profiles.tsv"
            path.write_text(table, encoding="utf-8")
            normal, _ = binary_patches.load_patch_rows(path)
            kvm, _ = binary_patches.load_patch_rows(path, kvm=True)
            rollback, _ = binary_patches.load_patch_rows(
                path,
                rollback_mode=True,
            )
            combined, _ = binary_patches.load_patch_rows(
                path,
                kvm=True,
                rollback_mode=True,
            )

        self.assertEqual([row.function for row in normal], ["always"])
        self.assertEqual([row.function for row in kvm], ["always", "kvm"])
        self.assertEqual(
            [row.function for row in rollback],
            ["always", "rollback"],
        )
        self.assertEqual(
            [row.function for row in combined],
            ["always", "kvm", "rollback"],
        )

    def test_exact_model_lk_tables_have_five_rollback_only_rows(self) -> None:
        patch_dir = ROOT_DIR / "security" / "samsung" / "patches"
        for path in sorted(patch_dir.glob("lk_*_selected_patches.tsv")):
            with self.subTest(table=path.name):
                rows = [
                    line
                    for line in path.read_text(encoding="utf-8").splitlines()
                    if line.startswith("rollback|")
                ]
                self.assertEqual(len(rows), 5)


class BootloaderModuleWiringTests(unittest.TestCase):
    def test_cross_module_dependencies_are_available(self) -> None:
        bootloader_signing = load_module("bootloader_signing_test", "bootloader_signing.py")
        bootloader_workflow = load_module("bootloader_workflow_test", "bootloader_workflow.py")
        sign_bootloader_pack = load_module("sign_bootloader_pack_test", "sign_bootloader_pack.py")

        for module, names in (
                (bootloader_signing, ("append_manifest", "tempfile")),
                (bootloader_workflow, ("key_paths", "require_file")),
                (sign_bootloader_pack, ("sign_stage2",)),
        ):
            for name in names:
                with self.subTest(module=module.__name__, name=name):
                    self.assertTrue(hasattr(module, name))


class SbootSplitMergeTests(unittest.TestCase):
    def test_round_trip_preserves_nonzero_gaps_and_tail(self) -> None:
        sboot_split = load_module("sboot_split_test", "split.py")
        sboot_merge = load_module("sboot_merge_test", "merge.py")
        soc = "Exynos9830\0"
        covered_end = 0x39B000
        source = bytearray(b"\x5A" * (covered_end + 257))
        source[0x82000:0xDB000] = bytes(
            index % 251 for index in range(0xDB000 - 0x82000)
        )
        source[covered_end:] = bytes(range(256)) + b"\xA5"

        with tempfile.TemporaryDirectory() as directory:
            work_dir = Path(directory)
            source_path = work_dir / "stock_sboot.bin"
            parts_dir = work_dir / "parts"
            output_path = work_dir / "merged_sboot.bin"
            source_path.write_bytes(source)

            sboot_split.split_sboot(str(source_path), soc, str(parts_dir))
            sboot_merge.merge_parts(str(parts_dir), soc, str(output_path), None)
            self.assertEqual(output_path.read_bytes(), source)

            manifest = json.loads((parts_dir / sboot_split.SPLIT_MANIFEST_NAME).read_text())
            self.assertEqual(manifest["version"], 2)
            self.assertEqual(
                [(gap["start"], gap["end"]) for gap in manifest["gaps"]],
                [(0x82000, 0xDB000)],
            )

            lk_path = parts_dir / "lk.bin"
            lk = bytearray(lk_path.read_bytes())
            lk[123] ^= 0xFF
            lk_path.write_bytes(lk)
            sboot_merge.merge_parts(str(parts_dir), soc, str(output_path), None)
            expected = bytearray(source)
            expected[0xDB000 + 123] ^= 0xFF
            self.assertEqual(output_path.read_bytes(), expected)

    def test_exynos9810_layout_has_one_non_overlapping_epbl_range(self) -> None:
        sboot_merge = load_module("sboot_merge_9810_test", "merge.py")
        ranges = sboot_merge.load_splits_for_soc("Exynos9810\0")
        self.assertEqual(
            [part_range for part_range in ranges if part_range[0] == "epbl.img"],
            [("epbl.img", 0x2000, 0x15000)],
        )


if __name__ == "__main__":
    unittest.main()
