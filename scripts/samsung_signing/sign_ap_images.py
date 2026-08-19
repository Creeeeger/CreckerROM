#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import subprocess
import sys
from pathlib import Path

from path_validation import require_file
from stage2_common import (
    STAGE2_FOOTER_SIZE,
    default_key_type,
    normalize_stage,
    parse_avb_footer,
    parse_stage2_footer,
    stage2_footer_candidate_sizes,
)


TOOLS_DIR = Path(__file__).resolve().parent
REPO_DIR = TOOLS_DIR.parents[1]
DEFAULT_KEYS_DIR = REPO_DIR / "security" / "samsung" / "exynos9830_crecker"

SIGNER_INFO_SIZE = 0x100
SIGNER_INFO_VERSION = b"SignerVer03"
SIGNER_INFO_BINARY_TYPE_OFFSET = 0x90
SIGNER_INFO_APPROVAL_OFFSET = 0x98
SIGNER_INFO_BINARY_NAME_OFFSET = 0x9C
SIGNER_INFO_BINARY_NAME_SIZE = 0x10

PHASE_IMAGES = {
    # AP images are signed in two phases because vbmeta does not exist until the
    # AVB pass, while boot/recovery images must be signed before AVB footers.
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
    # Existing footer metadata wins so re-signing does not accidentally switch
    # a stock image from TEE/REE/Stage-3 verification policy.
    for size in stage2_footer_candidate_sizes(stage, data):
        return parse_stage2_footer(data, size).key_type
    return default_key_type(stage)


def signer_info_for_footer(data: bytes, total_size: int) -> bytes | None:
    offset = total_size - STAGE2_FOOTER_SIZE - SIGNER_INFO_SIZE
    if offset < 0:
        return None
    signer_info = data[offset:offset + SIGNER_INFO_SIZE]
    if len(signer_info) != SIGNER_INFO_SIZE:
        return None
    if not signer_info.startswith(SIGNER_INFO_VERSION):
        return None
    return signer_info


def is_user_approved_signer_info(signer_info: bytes | None) -> bool:
    return bool(
        signer_info is not None
        and signer_info[SIGNER_INFO_BINARY_TYPE_OFFSET:
                        SIGNER_INFO_BINARY_TYPE_OFFSET + 4] == b"usr\0"
        and signer_info[SIGNER_INFO_APPROVAL_OFFSET:
                        SIGNER_INFO_APPROVAL_OFFSET + 4] == b"mrk\0"
    )


def reference_footer_metadata(reference: Path | None) -> tuple[int | None, bytes | None]:
    if reference is None:
        return None, None

    data = reference.read_bytes()
    # AP Stage-2 images for a firmware generation share the key index and
    # SignerInfo format. A stock boot image is therefore sufficient as the
    # reference, while this broader scan also accepts another stock AP image.
    footer_found = False
    for _, stage in selected_images("all"):
        for size in stage2_footer_candidate_sizes(stage, data):
            footer_found = True
            signer_info = signer_info_for_footer(data, size)
            if signer_info is None:
                continue
            if signer_info[SIGNER_INFO_BINARY_TYPE_OFFSET:
                           SIGNER_INFO_BINARY_TYPE_OFFSET + 4] != b"usr\0":
                raise ValueError(
                    f"{reference} SignerInfo is not a Samsung USER-binary template"
                )
            if signer_info[SIGNER_INFO_APPROVAL_OFFSET:
                           SIGNER_INFO_APPROVAL_OFFSET + 4] != b"mrk\0":
                raise ValueError(
                    f"{reference} SignerInfo is not marked as an approved binary"
                )
            return parse_stage2_footer(data, size).key_index, signer_info
    if footer_found:
        raise ValueError(
            f"{reference} has a Samsung Stage2 footer but no adjacent "
            "SignerVer03 block"
        )
    raise ValueError(f"{reference} has no recognizable Samsung Stage2 footer")


def signer_info_for_image(template: bytes | None, image_name: str) -> bytes:
    if template is None:
        raise RuntimeError(
            f"{image_name} needs a Samsung SignerInfo block; pass a stock "
            "--footer-reference from the target firmware"
        )
    try:
        encoded_name = image_name.encode("ascii")
    except UnicodeEncodeError as error:
        raise ValueError(f"Samsung binary name is not ASCII: {image_name}") from error
    # The stock field is a 15-character display name plus NUL. Samsung itself
    # stores longer names such as vbmeta_samsung.img as "vbmeta_samsung.".
    encoded_name = encoded_name[:SIGNER_INFO_BINARY_NAME_SIZE - 1]

    signer_info = bytearray(template)
    name_end = SIGNER_INFO_BINARY_NAME_OFFSET + SIGNER_INFO_BINARY_NAME_SIZE
    signer_info[SIGNER_INFO_BINARY_NAME_OFFSET:name_end] = (
        encoded_name + b"\0" * (SIGNER_INFO_BINARY_NAME_SIZE - len(encoded_name))
    )
    return bytes(signer_info)


def install_signer_info(
    image: Path,
    data: bytes,
    signer_info: bytes,
) -> bytes:
    output = data + signer_info
    image.write_bytes(output)
    print(
        f"[*] Added Samsung USER SignerInfo for {image.name} at "
        f"0x{len(data):X}"
    )
    return output


def prepare_unsigned_image(image: Path, stage: str, data: bytes) -> bytes:
    """Return the real payload to which a new Stage-2 footer can be appended.

    Recovery prebuilts commonly arrive AVB-wrapped but without a Samsung
    footer. Appending after that stale AVB footer would make avbtool unable to
    erase/re-sign it and would put the Stage-2 footer at the wrong boundary.
    Strip only the AVB wrapper described by its authenticated footer first.
    """
    avb = parse_avb_footer(data)
    if avb is None:
        return data
    if avb.original_image_size > len(data):
        raise ValueError(
            f"{image.name} AVB original_image_size points past the input file"
        )
    if avb.original_image_size < STAGE2_FOOTER_SIZE:
        raise ValueError(
            f"{image.name} AVB original payload is too small for Stage-2 signing"
        )

    payload = data[:avb.original_image_size]
    print(
        f"[*] Removing stale AVB wrapper from unsigned {image.name} before "
        f"adding its Samsung {normalize_stage(stage)} footer: "
        f"0x{len(data):X} -> 0x{len(payload):X}"
    )
    image.write_bytes(payload)
    return payload


def sign_image(args: argparse.Namespace, paths: dict[int, Path], pubs: dict[str, Path], image: Path, stage: str) -> bool:
    data = image.read_bytes()
    candidates = stage2_footer_candidate_sizes(stage, data)
    append_footer = not candidates
    has_signer_info = any(
        is_user_approved_signer_info(signer_info_for_footer(data, size))
        for size in candidates
    )
    new_signer_info = None
    if append_footer or not has_signer_info:
        # Validate the template before changing the input file. This keeps a
        # missing/bad reference from leaving a partially stripped AVB image.
        new_signer_info = signer_info_for_image(
            args.footer_signer_info,
            image.name,
        )
    if append_footer:
        data = prepare_unsigned_image(image, stage, data)
        data = install_signer_info(image, data, new_signer_info)
    elif not has_signer_info:
        # Older generated images may already contain our 0x210-byte footer but
        # lack the preceding 0x100-byte SignerInfo record. Remove the stale AVB
        # wrapper and footer, install USER metadata, then create a fresh footer.
        signed_size = candidates[0]
        data = data[:signed_size - STAGE2_FOOTER_SIZE]
        image.write_bytes(data)
        print(
            f"[*] Replacing metadata-less Samsung footer in {image.name}: "
            f"signed size 0x{signed_size:X}"
        )
        data = install_signer_info(image, data, new_signer_info)
        append_footer = True

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
    if append_footer:
        sign_cmd.append("--append-footer")
        if args.footer_key_index is not None:
            sign_cmd.extend(("--key-index", hex(args.footer_key_index)))
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
    parser = argparse.ArgumentParser(
        description="Add or replace Samsung Stage-2 signatures on AP boot-chain images"
    )
    parser.add_argument("--images-dir", type=Path, required=True, help="Directory containing *.img files")
    parser.add_argument("--keys-dir", type=Path, default=DEFAULT_KEYS_DIR, help=f"crecker_* key directory. Default: {DEFAULT_KEYS_DIR}")
    parser.add_argument("--phase", choices=("before-avb", "after-avb", "all"), default="all")
    parser.add_argument("--soc", default="exynos990")
    parser.add_argument("--rollback", type=lambda value: int(value, 0), required=True)
    parser.add_argument(
        "--footer-reference",
        type=Path,
        help=("Stock Samsung AP image supplying the key index and USER "
              "SignerInfo template for newly added footers"),
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Deprecated compatibility flag; every present image is always signed or fails",
    )
    parser.add_argument("--no-verify", dest="verify", action="store_false")
    parser.set_defaults(verify=True)
    args = parser.parse_args()

    if args.rollback < 0 or args.rollback >= 0x81:
        parser.error("--rollback must be in range 0..0x80")
    if not args.images_dir.is_dir():
        raise FileNotFoundError(args.images_dir)

    paths = key_paths(args.keys_dir)
    pubs = pubkey_paths(args.keys_dir)
    args.footer_key_index, args.footer_signer_info = reference_footer_metadata(
        args.footer_reference
    )

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
