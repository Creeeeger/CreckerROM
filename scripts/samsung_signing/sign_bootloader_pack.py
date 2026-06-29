#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import shutil
from pathlib import Path

from path_validation import require_file

TOOLS_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOLS_DIR.parents[1]
DEFAULT_KEYS_DIR = REPO_DIR / "security" / "samsung" / "exynos9830_crecker"
DEFAULT_PATCH_DIR = REPO_DIR / "security" / "samsung" / "patches"
DEFAULT_AVBTOOL = REPO_DIR / "external" / "android-tools" / "vendor" / "avb" / "avbtool.py"
DEFAULT_AVB_KEY = REPO_DIR / "security" / "avb" / "creckerrom_avb_private.pem"
LK_PATCH_MODEL_ALIASES = {
    "g980f": "g981b",
    "g985f": "g986b",
    "n980f": "n981b",
    "n985f": "n986b",
}

def normalize_model_id(model: str) -> str:
    value = model.strip().split("/", 1)[0].split("_", 1)[0]
    if value.upper().startswith("SM-"):
        value = value[3:]
    if not value:
        raise ValueError("empty firmware model")
    value = value.lower()
    return LK_PATCH_MODEL_ALIASES.get(value, value)


def default_patch_table_for_model(model: str) -> Path:
    return DEFAULT_PATCH_DIR / f"lk_{normalize_model_id(model)}_selected_patches.tsv"


def infer_model_from_stock_dir(stock_dir: Path) -> str | None:
    for part in reversed(stock_dir.parts):
        candidate = part.split("_", 1)[0]
        if candidate.upper().startswith("SM-"):
            return candidate
    return None


from bootloader_signing import (
    key_paths,
    sign_stage2,
)
from bootloader_workflow import (
    append_manifest,
    copy_stock_bootloader_inputs,
    merge_sboot,
    patch_lk,
    sign_external_bootloader_images,
    sign_split_sboot,
    split_sboot,
)

def main() -> None:
    parser = argparse.ArgumentParser(description="Patch, sign, and package Exynos9830 Samsung bootloader images")
    parser.add_argument("--stock-dir", type=Path, required=True, help="Extracted stock bootloader directory")
    parser.add_argument("--work-dir", type=Path, required=True, help="Scratch work directory")
    parser.add_argument("--out-dir", type=Path, required=True, help="Signed bootloader output directory")
    parser.add_argument("--keys-dir", type=Path, default=DEFAULT_KEYS_DIR,
                        help=f"crecker_* key directory. Default: {DEFAULT_KEYS_DIR}")
    parser.add_argument("--model",
                        help="Firmware default model used for the LK patch table, for example SM-G986B. "
                             "Defaults to inferring it from --stock-dir.")
    parser.add_argument("--bl1-model", help="BL1 target model label recorded in the signing manifest")
    parser.add_argument("--patch-table", type=Path,
                        help=f"LK TSV patch table. Default: {DEFAULT_PATCH_DIR}/lk_<default-model>_selected_patches.tsv")
    parser.add_argument("--avbtool", type=Path, default=DEFAULT_AVBTOOL,
                        help=f"Official avbtool.py path. Default: {DEFAULT_AVBTOOL}")
    parser.add_argument("--avb-key", type=Path, default=DEFAULT_AVB_KEY,
                        help=f"AVB private key for bootloader AVB footers. Default: {DEFAULT_AVB_KEY}")
    parser.add_argument("--avb-algorithm", default="SHA256_RSA4096")
    parser.add_argument("--no-avb", dest="sign_avb", action="store_false",
                        help="Do not re-sign AVB footers after Samsung signing")
    parser.add_argument("--keystorage-vbmeta-key", type=Path,
                        help="Pre-extracted AVB public key blob for the keystorage vbmeta slot. "
                             "Defaults to extracting it from --avb-key with avbtool.")
    parser.add_argument("--no-update-keystorage-vbmeta-key", dest="update_keystorage_vbmeta_key",
                        action="store_false",
                        help="Keep the stock keystorage vbmeta key instead of replacing it with the ROM AVB key")
    parser.add_argument("--soc", default="exynos990")
    parser.add_argument("--rollback", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--fwbl1-size", type=lambda value: int(value, 0), default=0x3000)
    parser.add_argument("--machine-id", type=lambda value: int(value, 0), default=0x9830)
    parser.add_argument("--model-id", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--evt", required=True)
    parser.add_argument("--tzar-patch-file",
                        help="Member path inside startup.tzar to patch before TZAR Stage-2 signing.")
    parser.add_argument("--tzar-patch-table", type=Path,
                        help="Byte-exact TSV patch table applied to --tzar-patch-file.")
    parser.add_argument("--decrypted-tzsw", type=Path,
                        help="Optional tzsw.img override. It may be stock encrypted or already decrypted; encrypted inputs are decrypted before patching.")
    parser.add_argument("--no-recrypt-tzsw", dest="recrypt_tzsw", action="store_false",
                        help="Leave tzsw.img decrypted after patching the userboot TZAR hash table. Debug only; normal BL packages should recrypt.")
    parser.add_argument("--no-verify", dest="verify", action="store_false")
    parser.set_defaults(verify=True, sign_avb=True, update_keystorage_vbmeta_key=True, recrypt_tzsw=True)
    args = parser.parse_args()

    if args.rollback < 0 or args.rollback >= 0x81:
        parser.error("--rollback must be in range 0..0x80")
    if not args.stock_dir.is_dir():
        raise FileNotFoundError(args.stock_dir)
    if (args.tzar_patch_file is None) != (args.tzar_patch_table is None):
        parser.error("--tzar-patch-file and --tzar-patch-table must be set together")
    patch_model = args.model or infer_model_from_stock_dir(args.stock_dir)
    patch_model_id = normalize_model_id(patch_model) if patch_model is not None else None
    if args.patch_table is None:
        if patch_model_id is None:
            parser.error("--patch-table or --model is required when --stock-dir does not include an SM-* model")
        args.patch_table = DEFAULT_PATCH_DIR / f"lk_{patch_model_id}_selected_patches.tsv"

    stock_sboot = require_file(args.stock_dir / "sboot.bin")
    paths = key_paths(args.keys_dir)

    if args.work_dir.exists():
        shutil.rmtree(args.work_dir)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for entry in args.out_dir.iterdir():
        if entry.is_file():
            entry.unlink()

    work_stock_dir = args.work_dir / "stock"
    parts_dir = args.work_dir / "sboot_parts"
    args.work_dir.mkdir(parents=True, exist_ok=True)
    copy_stock_bootloader_inputs(args.stock_dir, work_stock_dir)

    manifest = args.out_dir / "samsung_bootloader_manifest.txt"
    # Record model, patch, key, and AVB inputs so a signed BL folder can be
    # audited without reconstructing the command line.
    manifest.write_text(
        "\n".join(
            [
                "device_soc=exynos9830",
                f"rollback_revision={args.rollback}",
                f"keys_dir={args.keys_dir}",
                f"firmware_model={patch_model or 'unknown'}",
                f"lk_patch_model={patch_model_id or 'explicit'}",
                f"bl1_model={args.bl1_model or 'unspecified'}",
                f"bl1_model_id=0x{args.model_id:X}",
                f"bl1_evt={args.evt}",
                f"patch_table={args.patch_table}",
                f"tzar_patch_file={args.tzar_patch_file or 'none'}",
                f"tzar_patch_table={args.tzar_patch_table or 'none'}",
                f"avb_key={args.avb_key}",
                f"avb_algorithm={args.avb_algorithm}",
                "",
            ]
        ),
        encoding="utf-8",
    )

    split_sboot(stock_sboot, parts_dir)
    patch_lk(args, require_file(parts_dir / "lk.bin"))
    sign_split_sboot(args, paths, parts_dir, manifest)

    merged_sboot = merge_sboot(parts_dir, args.work_dir)
    signed_sboot = args.out_dir / "sboot.bin"
    shutil.copy2(merged_sboot, signed_sboot)
    if sign_stage2(args, paths, signed_sboot, "sboot", key_type=None, require_existing_footer=True):
        append_manifest(manifest, "signed_external", "sboot.bin=sboot")
    else:
        append_manifest(manifest, "copied_external", "sboot.bin=sboot-top-signature-not-present")

    sign_external_bootloader_images(args, paths, work_stock_dir, args.out_dir, manifest)

    print(f"[+] Samsung bootloader signing finished: {args.out_dir}")


if __name__ == "__main__":
    main()
