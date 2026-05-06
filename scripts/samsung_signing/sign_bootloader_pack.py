#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from stage2_common import (
    default_key_type,
    normalize_stage,
    parse_avb_footer,
    parse_stage2_footer,
    stage2_footer_candidate_sizes,
)


TOOLS_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOLS_DIR.parents[1]
DEFAULT_KEYS_DIR = REPO_DIR / "security" / "samsung" / "exynos9830_crecker"
DEFAULT_PATCH_TABLE = REPO_DIR / "security" / "samsung" / "patches" / "lk_985_selected_patches.tsv"
DEFAULT_AVBTOOL = REPO_DIR / "platform_external_avb-master" / "avbtool.py"
DEFAULT_AVB_KEY = REPO_DIR / "security" / "avb" / "creckerrom_avb_private.pem"
DEFAULT_ROLLBACK_REVISION = 23
KEYSTORAGE_VBMETA_KEY_NAME = "creckerrom_vbmeta.avbpubkey"

SBOOT_SPLIT_TARGETS = [
    ("epbl.img", "epbl", 0),
    ("bl2.img", "bl2", 1),
    ("lk.bin", "lk", 1),
    ("el3_mon.img", "el3_mon", 0),
]

EXTERNAL_BOOTLOADER_TARGETS = [
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
    "up_param.bin",
]


def require_file(path: Path) -> Path:
    if not path.is_file():
        raise FileNotFoundError(path)
    return path


def run_step(cmd: list[str], label: str, *, cwd: Path | None = None) -> None:
    print(f"[*] {label}", flush=True)
    subprocess.run(cmd, check=True, cwd=cwd)


def key_paths(keys_dir: Path) -> dict[str, Path]:
    return {
        "bl1_private": require_file(keys_dir / "crecker_private.pem"),
        "bl1_hmac": require_file(keys_dir / "crecker.hmac"),
        "stage2_tee_private": require_file(keys_dir / "crecker_stage2_tee_private.pem"),
        "stage2_tee_pub": require_file(keys_dir / "crecker_stage2_tee_pubkey.bin"),
        "stage2_ree_private": require_file(keys_dir / "crecker_stage2_ree_private.pem"),
        "stage2_ree_pub": require_file(keys_dir / "crecker_stage2_ree_pubkey.bin"),
        "stage3_private": require_file(keys_dir / "crecker_stage3_private.pem"),
        "stage3_pub": require_file(keys_dir / "crecker_stage3_pubkey.bin"),
    }


def private_key_for_type(paths: dict[str, Path], key_type: int) -> Path:
    if key_type == 2:
        return paths["stage3_private"]
    if key_type == 1:
        return paths["stage2_ree_private"]
    return paths["stage2_tee_private"]


def resolve_existing_key_type(stage: str, image: Path) -> int:
    data = image.read_bytes()
    for size in stage2_footer_candidate_sizes(stage, data):
        return parse_stage2_footer(data, size).key_type
    return default_key_type(stage)


def has_signable_footer(stage: str, image: Path) -> bool:
    return bool(stage2_footer_candidate_sizes(stage, image.read_bytes()))


def load_avbtool_module(avbtool_path: Path):
    spec = importlib.util.spec_from_file_location("crecker_avbtool", avbtool_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load avbtool module from {avbtool_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_avb_metadata(image: Path, avbtool_path: Path, fallback_partition: str) -> dict[str, object] | None:
    data = image.read_bytes()
    avb_footer = parse_avb_footer(data)
    if avb_footer is None:
        return None

    metadata: dict[str, object] = {
        "partition_name": fallback_partition,
        "partition_size": len(data),
        "kind": "hash",
        "rollback_index": 0,
        "rollback_index_location": 0,
        "hash_algorithm": "sha256",
    }

    if not avbtool_path.is_file():
        return metadata

    module = load_avbtool_module(avbtool_path)
    avb = module.Avb()
    handler = module.ImageHandler(str(image), read_only=True)
    _, header, descriptors, _ = avb._parse_image(handler)
    metadata["rollback_index"] = int(header.rollback_index)
    metadata["rollback_index_location"] = int(header.rollback_index_location)

    def avb_string(value: object) -> str:
        if isinstance(value, bytes):
            return value.decode("ascii", errors="replace").rstrip("\x00")
        return str(value).rstrip("\x00")

    for desc in descriptors:
        if isinstance(desc, module.AvbHashDescriptor):
            metadata["kind"] = "hash"
            metadata["partition_name"] = avb_string(desc.partition_name)
            hash_algorithm = getattr(desc, "hash_algorithm", None)
            if hash_algorithm:
                metadata["hash_algorithm"] = avb_string(hash_algorithm)
            break
        if isinstance(desc, module.AvbHashtreeDescriptor):
            metadata["kind"] = "hashtree"
            metadata["partition_name"] = avb_string(desc.partition_name)
            hash_algorithm = getattr(desc, "hash_algorithm", None)
            if hash_algorithm:
                metadata["hash_algorithm"] = avb_string(hash_algorithm)
            break

    return metadata


def ensure_avb_key_file(args: argparse.Namespace) -> None:
    if args.avb_key.is_file():
        return

    args.avb_key.parent.mkdir(parents=True, exist_ok=True)
    bits = "4096"
    if "RSA2048" in args.avb_algorithm:
        bits = "2048"
    elif "RSA8192" in args.avb_algorithm:
        bits = "8192"

    run_step(["openssl", "genrsa", "-out", str(args.avb_key), bits], f"Generating AVB key {args.avb_key}")


def ensure_avb_key(args: argparse.Namespace) -> None:
    if not args.sign_avb:
        return
    ensure_avb_key_file(args)


def resolve_keystorage_vbmeta_key(args: argparse.Namespace) -> Path:
    if args.keystorage_vbmeta_key is not None:
        return require_file(args.keystorage_vbmeta_key)

    if not args.avbtool.is_file():
        raise FileNotFoundError(args.avbtool)

    ensure_avb_key_file(args)
    key_path = args.work_dir / KEYSTORAGE_VBMETA_KEY_NAME
    run_step(
        [
            sys.executable,
            str(args.avbtool),
            "extract_public_key",
            "--key",
            str(args.avb_key),
            "--output",
            str(key_path),
        ],
        f"Extracting AVB public key for keystorage vbmeta slot",
    )
    return require_file(key_path)


def patch_keystorage_vbmeta_key(args: argparse.Namespace, image: Path, manifest: Path) -> None:
    if not args.update_keystorage_vbmeta_key:
        append_manifest(manifest, "keystorage_vbmeta_key", "preserved")
        return

    vbmeta_key = resolve_keystorage_vbmeta_key(args)
    vbmeta_key_size = len(vbmeta_key.read_bytes())
    run_step(
        [
            sys.executable,
            str(TOOLS_DIR / "keystorage_gen_tool.py"),
            "--template",
            str(image),
            "--vbmeta-key",
            str(vbmeta_key),
            "--vbmeta-key-size",
            str(vbmeta_key_size),
            "--preserve-date-user",
            "-o",
            str(image),
        ],
        f"Patching keystorage.bin vbmeta key from {vbmeta_key.name}",
    )
    append_manifest(manifest, "keystorage_vbmeta_key", f"{vbmeta_key}:size{vbmeta_key_size}")
    append_manifest(manifest, "keystorage_cp_key", "preserved")
    append_manifest(manifest, "keystorage_fimc_key", "preserved")


def resign_avb_footer_if_present(args: argparse.Namespace, image: Path, stage: str) -> bool:
    if not args.sign_avb:
        return False
    if not args.avbtool.is_file():
        raise FileNotFoundError(args.avbtool)

    metadata = read_avb_metadata(image, args.avbtool, stage)
    if metadata is None:
        return False

    ensure_avb_key(args)
    partition_name = str(metadata["partition_name"])
    partition_size = str(metadata["partition_size"])
    kind = str(metadata["kind"])
    hash_algorithm = str(metadata["hash_algorithm"])
    rollback_index = str(metadata["rollback_index"])
    rollback_location = str(metadata["rollback_index_location"])
    avb_cmd = "add_hashtree_footer" if kind == "hashtree" else "add_hash_footer"

    run_step(
        [
            sys.executable,
            str(args.avbtool),
            "erase_footer",
            "--image",
            str(image),
        ],
        f"Erasing stale AVB footer from {image.name}",
    )
    run_step(
        [
            sys.executable,
            str(args.avbtool),
            avb_cmd,
            "--image",
            str(image),
            "--partition_name",
            partition_name,
            "--partition_size",
            partition_size,
            "--algorithm",
            args.avb_algorithm,
            "--key",
            str(args.avb_key),
            "--hash_algorithm",
            hash_algorithm,
            "--rollback_index",
            rollback_index,
            "--rollback_index_location",
            rollback_location,
        ],
        f"Re-signing AVB footer for {image.name} ({partition_name}, {kind})",
    )
    with tempfile.TemporaryDirectory(prefix="crecker_avb_verify_") as verify_dir:
        verify_image = Path(verify_dir) / f"{partition_name}{image.suffix or '.img'}"
        os.symlink(image.resolve(), verify_image)
        run_step(
            [
                sys.executable,
                str(args.avbtool),
                "verify_image",
                "--image",
                str(verify_image),
                "--key",
                str(args.avb_key),
            ],
            f"Verifying AVB footer for {image.name}",
        )
    return True


def sign_fwbl1(args: argparse.Namespace, paths: dict[str, Path], image: Path) -> None:
    cmd = [
        sys.executable,
        str(TOOLS_DIR / "sign_tool.py"),
        "--soc",
        args.soc,
        "-i",
        str(image),
        "-o",
        str(image),
        "-k",
        str(paths["bl1_private"]),
        "-H",
        str(paths["bl1_hmac"]),
        "-s",
        hex(args.fwbl1_size),
        "-r",
        str(args.rollback),
        "-ma",
        hex(args.machine_id),
        "-m",
        hex(args.model_id),
        "-e",
        args.evt,
        "-t",
        str(paths["stage2_tee_pub"]),
        "-re",
        str(paths["stage2_ree_pub"]),
    ]
    run_step(cmd, f"Signing fwbl1.img, rp={args.rollback}")


def verify_stage2(args: argparse.Namespace, paths: dict[str, Path], image: Path, stage: str) -> None:
    if not args.verify:
        return

    cmd = [
        sys.executable,
        str(TOOLS_DIR / "stage2_verify_tool.py"),
        "--soc",
        args.soc,
        "--stage",
        stage,
        "-i",
        str(image),
        "--tee-pub-key",
        str(paths["stage2_tee_pub"]),
        "--ree-pub-key",
        str(paths["stage2_ree_pub"]),
        "--stage3-pub-key",
        str(paths["stage3_pub"]),
    ]
    run_step(cmd, f"Verifying {image.name}")


def sign_stage2(
    args: argparse.Namespace,
    paths: dict[str, Path],
    image: Path,
    stage: str,
    *,
    key_type: int | None = None,
    require_existing_footer: bool,
) -> bool:
    stage = normalize_stage(stage)
    if require_existing_footer and not has_signable_footer(stage, image):
        print(f"[!] {image.name} has no recognizable Samsung Stage2 footer/trailer")
        return False

    if key_type is None:
        key_type = resolve_existing_key_type(stage, image)
    private_key = private_key_for_type(paths, key_type)

    cmd = [
        sys.executable,
        str(TOOLS_DIR / "stage2_sign_tool.py"),
        "--soc",
        args.soc,
        "--stage",
        stage,
        "-i",
        str(image),
        "-o",
        str(image),
        "-k",
        str(private_key),
        "-r",
        str(args.rollback),
        "--key-type",
        str(key_type),
    ]
    run_step(cmd, f"Signing {image.name} as {stage}, key_type={key_type}, rp={args.rollback}")
    verify_stage2(args, paths, image, stage)
    if resign_avb_footer_if_present(args, image, stage):
        verify_stage2(args, paths, image, stage)
    return True


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


def append_manifest(manifest: Path, key: str, value: str) -> None:
    with manifest.open("a", encoding="utf-8") as fh:
        fh.write(f"{key}={value}\n")


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
    for filename, stage, required_if_present in EXTERNAL_BOOTLOADER_TARGETS:
        source = work_stock_dir / filename
        if not source.is_file():
            append_manifest(manifest, "missing_optional", filename)
            continue

        image = out_dir / filename
        shutil.copy2(source, image)
        if stage == "keystorage":
            patch_keystorage_vbmeta_key(args, image, manifest)
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


def main() -> None:
    parser = argparse.ArgumentParser(description="Patch, sign, and package Exynos9830 Samsung bootloader images")
    parser.add_argument("--stock-dir", type=Path, required=True, help="Extracted stock bootloader directory")
    parser.add_argument("--work-dir", type=Path, required=True, help="Scratch work directory")
    parser.add_argument("--out-dir", type=Path, required=True, help="Signed bootloader output directory")
    parser.add_argument("--keys-dir", type=Path, default=DEFAULT_KEYS_DIR, help=f"crecker_* key directory. Default: {DEFAULT_KEYS_DIR}")
    parser.add_argument("--patch-table", type=Path, default=DEFAULT_PATCH_TABLE, help=f"LK TSV patch table. Default: {DEFAULT_PATCH_TABLE}")
    parser.add_argument("--avbtool", type=Path, default=DEFAULT_AVBTOOL, help=f"Official avbtool.py path. Default: {DEFAULT_AVBTOOL}")
    parser.add_argument("--avb-key", type=Path, default=DEFAULT_AVB_KEY, help=f"AVB private key for bootloader AVB footers. Default: {DEFAULT_AVB_KEY}")
    parser.add_argument("--avb-algorithm", default="SHA256_RSA4096")
    parser.add_argument("--no-avb", dest="sign_avb", action="store_false", help="Do not re-sign AVB footers after Samsung signing")
    parser.add_argument("--keystorage-vbmeta-key", type=Path,
                        help="Pre-extracted AVB public key blob for the keystorage vbmeta slot. "
                             "Defaults to extracting it from --avb-key with avbtool.")
    parser.add_argument("--no-update-keystorage-vbmeta-key", dest="update_keystorage_vbmeta_key",
                        action="store_false",
                        help="Keep the stock keystorage vbmeta key instead of replacing it with the ROM AVB key")
    parser.add_argument("--soc", default="exynos990")
    parser.add_argument("--rollback", type=lambda value: int(value, 0), default=DEFAULT_ROLLBACK_REVISION)
    parser.add_argument("--fwbl1-size", type=lambda value: int(value, 0), default=0x3000)
    parser.add_argument("--machine-id", type=lambda value: int(value, 0), default=0x9830)
    parser.add_argument("--model-id", type=lambda value: int(value, 0), default=0x142)
    parser.add_argument("--evt", default="11")
    parser.add_argument("--no-verify", dest="verify", action="store_false")
    parser.set_defaults(verify=True, sign_avb=True, update_keystorage_vbmeta_key=True)
    args = parser.parse_args()

    if args.rollback < 0 or args.rollback >= 0x81:
        parser.error("--rollback must be in range 0..0x80")
    if not args.stock_dir.is_dir():
        raise FileNotFoundError(args.stock_dir)

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
    manifest.write_text(
        "\n".join(
            [
                "device_soc=exynos9830",
                f"rollback_revision={args.rollback}",
                f"keys_dir={args.keys_dir}",
                f"patch_table={args.patch_table}",
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
