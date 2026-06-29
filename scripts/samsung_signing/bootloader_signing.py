#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from avb_cli import avb_environment, read_footer_metadata
from path_validation import require_file
from stage2_common import (
    default_key_type,
    normalize_stage,
    parse_stage2_footer,
    stage2_footer_candidate_sizes,
)

TOOLS_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOLS_DIR.parents[1]
DEFAULT_AVBTOOL = REPO_DIR / "external" / "android-tools" / "vendor" / "avb" / "avbtool.py"
DEFAULT_AVB_KEY = REPO_DIR / "security" / "avb" / "creckerrom_avb_private.pem"
# keystorage stores the AVB public blob, not the PEM, so extract it into the
# work directory before patching the vbmeta key slot.
KEYSTORAGE_VBMETA_KEY_NAME = "creckerrom_vbmeta.avbpubkey"

def run_step(cmd: list[str], label: str, *, cwd: Path | None = None) -> None:
    print(f"[*] {label}", flush=True)
    subprocess.run(cmd, check=True, cwd=cwd, env=avb_environment())


def append_manifest(manifest: Path, key: str, value: str) -> None:
    with manifest.open("a", encoding="utf-8") as fh:
        fh.write(f"{key}={value}\n")


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


def ensure_avb_key_file(args: argparse.Namespace) -> None:
    if args.avb_key.is_file():
        return

    args.avb_key.parent.mkdir(parents=True, exist_ok=True)
    bits = "4096"
    if "RSA2048" in args.avb_algorithm:
        bits = "2048"
    elif "RSA8192" in args.avb_algorithm:
        bits = "8192"

    run_step(
        [
            "openssl",
            "genpkey",
            "-algorithm",
            "RSA",
            "-pkeyopt",
            f"rsa_keygen_bits:{bits}",
            "-out",
            str(args.avb_key),
        ],
        f"Generating AVB key {args.avb_key}",
    )


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

    # Samsung Stage-2 signing changes bytes inside the AVB-protected payload;
    # replay the original footer metadata after the secure-boot signature.
    metadata = read_footer_metadata(image, args.avbtool, stage)
    if metadata is None:
        return False

    ensure_avb_key(args)
    partition_name = str(metadata["partition_name"])
    partition_size = str(metadata["partition_size"])
    kind = str(metadata["kind"])
    hash_algorithm = str(metadata["hash_algorithm"])
    rollback_index = str(args.rollback)
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
    # If an AVB footer is present, the footer must be re-signed after Samsung
    # signing and then the Samsung signature is verified again in wrapper mode.
    if resign_avb_footer_if_present(args, image, stage):
        verify_stage2(args, paths, image, stage)
    return True
