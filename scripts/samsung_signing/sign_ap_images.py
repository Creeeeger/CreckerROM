#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import subprocess
import sys
from pathlib import Path

from stage2_common import (
    default_key_type,
    normalize_stage,
    parse_stage2_footer,
    stage2_footer_candidate_sizes,
)


TOOLS_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOLS_DIR.parents[1]
DEFAULT_KEYS_DIR = REPO_DIR / "security" / "samsung" / "exynos9830_crecker"
DEFAULT_ROLLBACK_REVISION = 23

PHASE_IMAGES = {
    "before-avb": [
        ("boot.img", "boot"),
        ("dtbo.img", "dtbo"),
        ("recovery.img", "recovery"),
        ("vendor_boot.img", "vendor_boot"),
        ("init_boot.img", "init_boot"),
    ],
    "after-avb": [
        ("vbmeta.img", "vbmeta"),
        ("vbmeta_samsung.img", "vbmeta_samsung"),
    ],
}


def require_file(path: Path) -> Path:
    if not path.is_file():
        raise FileNotFoundError(path)
    return path


def run_step(cmd: list[str], label: str) -> None:
    print(f"[*] {label}", flush=True)
    subprocess.run(cmd, check=True)


def key_paths(keys_dir: Path) -> dict[int, Path]:
    return {
        0: require_file(keys_dir / "crecker_stage2_tee_private.pem"),
        1: require_file(keys_dir / "crecker_stage2_ree_private.pem"),
        2: require_file(keys_dir / "crecker_stage3_private.pem"),
    }


def pubkey_paths(keys_dir: Path) -> dict[str, Path]:
    return {
        "tee": require_file(keys_dir / "crecker_stage2_tee_pubkey.bin"),
        "ree": require_file(keys_dir / "crecker_stage2_ree_pubkey.bin"),
        "stage3": require_file(keys_dir / "crecker_stage3_pubkey.bin"),
    }


def resolve_key_type(stage: str, data: bytes) -> int:
    for size in stage2_footer_candidate_sizes(stage, data):
        return parse_stage2_footer(data, size).key_type
    return default_key_type(stage)


def image_is_signable(stage: str, data: bytes) -> bool:
    return bool(stage2_footer_candidate_sizes(stage, data))


def sign_image(args: argparse.Namespace, paths: dict[int, Path], pubs: dict[str, Path], image: Path, stage: str) -> bool:
    data = image.read_bytes()
    if not image_is_signable(stage, data):
        message = f"{image.name} has no recognizable Samsung Stage2 footer/trailer; skipping"
        if args.strict:
            raise RuntimeError(message)
        print(f"[!] {message}")
        return False

    key_type = resolve_key_type(stage, data)
    private_key = paths[key_type]
    stage = normalize_stage(stage)

    sign_cmd = [
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
    run_step(sign_cmd, f"Signing {image.name} as {stage}, key_type={key_type}, rp={args.rollback}")

    if args.verify:
        verify_cmd = [
            sys.executable,
            str(TOOLS_DIR / "stage2_verify_tool.py"),
            "--soc",
            args.soc,
            "--stage",
            stage,
            "-i",
            str(image),
            "--tee-pub-key",
            str(pubs["tee"]),
            "--ree-pub-key",
            str(pubs["ree"]),
            "--stage3-pub-key",
            str(pubs["stage3"]),
        ]
        run_step(verify_cmd, f"Verifying {image.name}")

    return True


def selected_images(phase: str) -> list[tuple[str, str]]:
    if phase == "all":
        images: list[tuple[str, str]] = []
        for phase_name in ("before-avb", "after-avb"):
            for entry in PHASE_IMAGES[phase_name]:
                if entry not in images:
                    images.append(entry)
        return images
    return PHASE_IMAGES[phase]


def main() -> None:
    parser = argparse.ArgumentParser(description="Samsung-sign AP boot-chain images that already carry SignerVer metadata")
    parser.add_argument("--images-dir", type=Path, required=True, help="Directory containing *.img files")
    parser.add_argument("--keys-dir", type=Path, default=DEFAULT_KEYS_DIR, help=f"crecker_* key directory. Default: {DEFAULT_KEYS_DIR}")
    parser.add_argument("--phase", choices=("before-avb", "after-avb", "all"), default="all")
    parser.add_argument("--soc", default="exynos990")
    parser.add_argument("--rollback", type=lambda value: int(value, 0), default=DEFAULT_ROLLBACK_REVISION)
    parser.add_argument("--strict", action="store_true", help="Fail when a present image has no Samsung signature area")
    parser.add_argument("--no-verify", dest="verify", action="store_false")
    parser.set_defaults(verify=True)
    args = parser.parse_args()

    if args.rollback < 0 or args.rollback >= 0x81:
        parser.error("--rollback must be in range 0..0x80")
    if not args.images_dir.is_dir():
        raise FileNotFoundError(args.images_dir)

    paths = key_paths(args.keys_dir)
    pubs = pubkey_paths(args.keys_dir)

    signed = 0
    missing = 0
    skipped = 0
    for filename, stage in selected_images(args.phase):
        image = args.images_dir / filename
        if not image.is_file():
            missing += 1
            continue
        if sign_image(args, paths, pubs, image, stage):
            signed += 1
        else:
            skipped += 1

    print(f"[+] Samsung AP signing finished: signed={signed} skipped={skipped} missing={missing}")


if __name__ == "__main__":
    main()
