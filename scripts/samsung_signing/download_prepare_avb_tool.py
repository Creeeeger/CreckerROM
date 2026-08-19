#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

"""Prepare Samsung sparse signer records before AVB hashes the filesystem.

Exynos LK removes FullHashSig while receiving a sparse image, then hashes and
writes the normalized bytes. AVB must consequently be generated with the
0x200-byte FullHashSig field zero, while the header and SignerInfo metadata are
already final. The final download-signing pass fills only FullHashSig.
"""

import argparse
import shutil
from pathlib import Path

from common import DEFAULT_SOC, get_soc_config
from download_signature_common import (
    copy_with_download_reference,
    download_signature_header,
    load_super_signing_defaults,
    parse_download_signature_layout,
    select_download_header_values,
    update_download_signer_info_rollback,
    write_download_signature,
)
from stage2_common import (
    SIGN_TYPE_ECDSA_NIST_P384,
    STAGE2_SIGNATURE_SIZE,
    signer_info_with_rollback,
    validate_signing_args,
)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Prepare a sparse Samsung download signer block for later AVB signing"
    )
    parser.add_argument("--soc", default=DEFAULT_SOC)
    parser.add_argument("-i", "--input", required=True, type=Path)
    parser.add_argument("-o", "--output", required=True, type=Path)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("-r", "--rp-cnt", required=True, type=lambda value: int(value, 0))
    parser.add_argument(
        "--sign-type",
        type=lambda value: int(value, 0),
        default=SIGN_TYPE_ECDSA_NIST_P384,
    )
    parser.add_argument("--key-type", type=lambda value: int(value, 0))
    parser.add_argument("--key-index", type=lambda value: int(value, 0))
    args = parser.parse_args()

    try:
        soc = get_soc_config(args.soc)
    except ValueError as error:
        parser.error(str(error))
    if soc["name"] != "exynos990":
        parser.error("Sparse download signing is implemented for Exynos 990 / Exynos9830 only")
    if not args.input.is_file():
        parser.error(f"--input not found: {args.input}")
    if not args.reference.is_file():
        parser.error(f"--reference not found: {args.reference}")
    if args.input.resolve() == args.output.resolve():
        parser.error("--input and --output must be different paths")

    try:
        reference = load_super_signing_defaults(args.reference)
    except (OSError, ValueError) as error:
        parser.error(f"Could not read --reference {args.reference}: {error}")

    try:
        layout = parse_download_signature_layout(args.input)
    except ValueError:
        layout = None

    if layout is None:
        key_type = reference.key_type if args.key_type is None else args.key_type
        key_index = reference.key_index if args.key_index is None else args.key_index
        values = args.rp_cnt, args.sign_type, key_type, key_index
        header = download_signature_header(*values)
        layout = copy_with_download_reference(
            args.input,
            args.output,
            header,
            signer_info_with_rollback(reference.signer_info, args.rp_cnt),
        )
    else:
        values = select_download_header_values(
            layout,
            args.rp_cnt,
            args.sign_type,
            args.key_type,
            args.key_index,
        )
        header = download_signature_header(*values)
        shutil.copyfile(args.input, args.output)
        update_download_signer_info_rollback(
            args.output,
            layout,
            args.rp_cnt,
        )

    validate_signing_args(
        argparse.Namespace(
            rp_cnt=values[0],
            sign_type=values[1],
            key_type=values[2],
            key_index=values[3],
        ),
        parser,
    )
    # This is the representation LK writes to the partition after preserving
    # FullHashSig in a separate verification buffer.
    write_download_signature(
        args.output,
        layout,
        header,
        b"\x00" * STAGE2_SIGNATURE_SIZE,
    )

    prepared = parse_download_signature_layout(args.output)
    print(f"Prepared: {args.output}")
    print(f"Reference: {args.reference}")
    print(f"Signature record: 0x{prepared.signature_record_offset:X}")
    print(f"Signer info: 0x{prepared.signer_info_offset:X} (SignerVer0{prepared.signer_version})")
    print(
        f"rp/sign/key/key-index: {values[0]}/0x{values[1]:X}/"
        f"{values[2]}/0x{values[3]:X}"
    )
    print(f"SignerInfo rollback: system={args.rp_cnt} kernel={args.rp_cnt}")
    print("FullHashSig: zero (ready for AVB)")


if __name__ == "__main__":
    main()
