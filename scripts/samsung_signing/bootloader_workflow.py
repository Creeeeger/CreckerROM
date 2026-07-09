#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import shutil
import sys
from pathlib import Path

from bootloader_signing import (
    append_manifest,
    key_paths,
    patch_keystorage_vbmeta_key,
    run_step,
    sign_fwbl1,
    sign_stage2,
    verify_stage2,
)
from path_validation import require_file
from tzsw_crypt_tool import (
    decrypt_tzsw,
    encrypt_tzsw,
    is_clear_tzsw,
    tzsw_stored_digest,
    update_tzsw_digest,
    verify_tzsw_digest,
)

TOOLS_DIR = Path(__file__).resolve().parent
SBOOT_SPLIT_TARGETS = [
    ("epbl.img", "epbl", 0),
    ("bl2.img", "bl2", 1),
    ("lk.bin", "lk", 1),
    ("el3_mon.img", "el3_mon", 0),
]
EXTERNAL_BOOTLOADER_TARGETS = [
    # Third tuple value means "fail if this present file cannot be signed";
    # false allows known passthrough-style images to remain copied.
    ("ldfw.img", "ldfw", True),
    ("tzsw.img", "tzsw", True),
    ("keystorage.bin", "keystorage", True),
    ("harx.bin", "harx", True),
    ("ssp.img", "spayload", False),
    ("tzar.img", "tzar", True),
    ("uh.bin", "uh", True),
    ("vbmeta_samsung.img", "vbmeta_samsung", False),
]
PASSTHROUGH_BOOTLOADER_FILES = [
    # up_param.bin is flashed with the bootloader package but is not a
    # Samsung Stage-2 signed boot-chain image.
    "up_param.bin",
]

def copy_stock_bootloader_inputs(stock_dir: Path, work_stock_dir: Path) -> None:
    work_stock_dir.mkdir(parents=True, exist_ok=True)
    for entry in stock_dir.iterdir():
        if entry.is_file():
            shutil.copy2(entry, work_stock_dir / entry.name)


def split_sboot(stock_sboot: Path, parts_dir: Path) -> None:
    if parts_dir.exists():
        shutil.rmtree(parts_dir)
    run_step(
        [
            sys.executable,
            str(TOOLS_DIR / "split.py"),
            str(stock_sboot),
            "--soc",
            "Exynos9830",
            "-o",
            str(parts_dir),
        ],
        "Splitting stock sboot.bin",
    )


def patch_lk(args: argparse.Namespace, lk_path: Path) -> None:
    if not args.patch_table.is_file():
        raise FileNotFoundError(args.patch_table)

    run_step(
        [
            sys.executable,
            str(TOOLS_DIR / "apply_lk_patches.py"),
            "--input",
            str(lk_path),
            "--patch-table",
            str(args.patch_table),
        ],
        "Applying LK selected byte patches",
    )


def merge_sboot(parts_dir: Path, work_dir: Path) -> Path:
    merged = work_dir / "sboot.bin"
    if merged.exists():
        merged.unlink()
    run_step(
        [
            sys.executable,
            str(TOOLS_DIR / "merge.py"),
            str(parts_dir),
            "Exynos9830",
        ],
        "Merging signed SBoot split images",
        cwd=work_dir,
    )
    return require_file(merged)


def sign_split_sboot(args: argparse.Namespace, paths: dict[str, Path], parts_dir: Path, manifest: Path) -> None:
    sign_fwbl1(args, paths, require_file(parts_dir / "fwbl1.img"))
    append_manifest(manifest, "signed_split", "fwbl1.img=bl1")

    for filename, stage, key_type in SBOOT_SPLIT_TARGETS:
        image = require_file(parts_dir / filename)
        sign_stage2(args, paths, image, stage, key_type=key_type, require_existing_footer=False)
        append_manifest(manifest, "signed_split", f"{filename}={stage}:key_type{key_type}")


def sign_external_bootloader_images(
        args: argparse.Namespace,
        paths: dict[str, Path],
        work_stock_dir: Path,
        out_dir: Path,
        manifest: Path,
) -> None:
    patch_tzar_hashes = args.tzar_patch_file is not None and (work_stock_dir / "tzar.img").is_file()
    for filename, stage, required_if_present in EXTERNAL_BOOTLOADER_TARGETS:
        source = work_stock_dir / filename
        if filename == "tzsw.img" and args.decrypted_tzsw is not None:
            source = require_file(args.decrypted_tzsw)
            append_manifest(manifest, "source_override", f"tzsw.img={source}")
        if not source.is_file():
            append_manifest(manifest, "missing_optional", filename)
            continue

        image = out_dir / filename
        shutil.copy2(source, image)
        if stage == "tzsw" and patch_tzar_hashes:
            # TZAR member changes require a matching hash-table update inside
            # clear TZSW, so defer TZSW signing until after tzar.img is rebuilt.
            prepare_tzsw_for_tzar_hash_patch(image, manifest)
            append_manifest(manifest, "prepared_external", "tzsw.img=tzsw:clear-for-tzar-hashes")
            continue
        if stage == "keystorage":
            patch_keystorage_vbmeta_key(args, image, manifest)
        if stage == "tzar" and args.tzar_patch_file is not None:
            patch_tzar_member(args, image, manifest)
            patch_tzsw_tzar_hashes(args, paths, out_dir / "tzsw.img", image, manifest)
            continue
        signed = sign_stage2(args, paths, image, stage, key_type=None, require_existing_footer=True)
        if not signed and required_if_present:
            raise RuntimeError(f"{filename} is present but did not expose a signable Samsung Stage2 footer")
        append_manifest(manifest, "signed_external" if signed else "copied_external", f"{filename}={stage}")

    for filename in PASSTHROUGH_BOOTLOADER_FILES:
        source = work_stock_dir / filename
        if not source.is_file():
            continue
        shutil.copy2(source, out_dir / filename)
        append_manifest(manifest, "copied_external", f"{filename}=passthrough")


def patch_tzar_member(args: argparse.Namespace, image: Path, manifest: Path) -> None:
    require_file(args.tzar_patch_table)
    run_step(
        [
            sys.executable,
            str(TOOLS_DIR / "tzar_tool.py"),
            "patch-member",
            "-i",
            str(image),
            "-o",
            str(image),
            "--member",
            args.tzar_patch_file,
            "--patch-table",
            str(args.tzar_patch_table),
            "--keys-dir",
            str(args.keys_dir),
            "--soc",
            args.soc,
            "--rp-cnt",
            str(args.rollback),
        ],
        f"Patching TZAR member {args.tzar_patch_file} and signing {image.name}",
    )
    verify_stage2(args, key_paths(args.keys_dir), image, "tzar")
    append_manifest(manifest, "patched_tzar_member", f"{args.tzar_patch_file}:{args.tzar_patch_table}")
    append_manifest(manifest, "signed_external", "tzar.img=tzar:member-tsv")


def prepare_tzsw_for_tzar_hash_patch(image: Path, manifest: Path) -> None:
    data = image.read_bytes()
    if is_clear_tzsw(data):
        if not verify_tzsw_digest(data):
            raise ValueError(
                f"{image.name} is already clear but its TZSW BiEn digest is invalid; "
                "use encrypted stock tzsw.img or decrypt it with tzsw_crypt_tool.py"
            )
        append_manifest(manifest, "tzsw_crypto", f"{image.name}=already-clear")
        return

    # The userboot TZAR hash table lives in the encrypted TZSW region; patch it
    # only after decrypting to the clear representation.
    clear = decrypt_tzsw(data)
    if not is_clear_tzsw(clear):
        raise ValueError(
            f"{image.name} did not expose userboot after Exynos9830 TZSW decrypt; "
            "check that the image matches this SoC/firmware generation"
        )
    image.write_bytes(clear)
    append_manifest(manifest, "tzsw_crypto", f"{image.name}=decrypted-for-patch")


def recrypt_tzsw_after_hash_patch(args: argparse.Namespace, image: Path, manifest: Path) -> None:
    data = image.read_bytes()
    if not is_clear_tzsw(data):
        raise ValueError(f"{image.name} is not clear at TZSW recrypt time")
    # The BiEn digest covers the clear region and must be refreshed before any
    # optional AES-CBC re-encryption.
    data = update_tzsw_digest(data)
    image.write_bytes(data)
    append_manifest(manifest, "tzsw_crypto", f"{image.name}=bien-digest:{tzsw_stored_digest(data).hex()}")
    if not args.recrypt_tzsw:
        append_manifest(manifest, "tzsw_crypto", f"{image.name}=left-clear")
        return
    image.write_bytes(encrypt_tzsw(data))
    append_manifest(manifest, "tzsw_crypto", f"{image.name}=recrypted-after-patch")


def patch_tzsw_tzar_hashes(
        args: argparse.Namespace,
        paths: dict[str, Path],
        tzsw_image: Path,
        tzar_image: Path,
        manifest: Path,
) -> None:
    require_file(tzsw_image)
    require_file(tzar_image)
    run_step(
        [
            sys.executable,
            str(TOOLS_DIR / "tzar_tool.py"),
            "patch-tzsw-hashes",
            "-i",
            str(tzsw_image),
            "-o",
            str(tzsw_image),
            "--tzar",
            str(tzar_image),
        ],
        f"Patching {tzsw_image.name} userboot TZAR hash table from {tzar_image.name}",
    )
    recrypt_tzsw_after_hash_patch(args, tzsw_image, manifest)
    if not sign_stage2(args, paths, tzsw_image, "tzsw", key_type=None, require_existing_footer=True):
        raise RuntimeError(
            f"{tzsw_image.name} did not expose a signable Samsung Stage2 footer after TZAR hash patching")
    append_manifest(manifest, "patched_tzsw_tzar_hashes", str(tzar_image))
    append_manifest(manifest, "signed_external", "tzsw.img=tzsw:tzar-hashes")
