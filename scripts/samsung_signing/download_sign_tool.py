# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import argparse
from pathlib import Path

from common import DEFAULT_SOC, get_soc_config
from download_signature_common import (
    DEFAULT_SUPER_REFERENCE,
    SIGNER_INFO_SIZE,
    copy_with_download_signature,
    copy_with_super_signature,
    download_final_digest,
    download_signature_header,
    load_super_signing_defaults,
    parse_download_signature_layout,
    read_download_signer_info,
    read_super_embedded_signer_info,
    signer_info_binary_name,
    signer_info_quick_build_id,
    sparse_image_has_super_metadata,
    write_download_signature,
)
from stage2_common import (
    DEFAULT_KEY_INDEX,
    SIGN_TYPE_ECDSA_NIST_P384,
    default_private_key_for_key_type,
    is_p384_private_key,
    load_private_key,
    sign_digest,
    validate_signing_args,
)

STAGE2_SOC_HELP = "Target SoC: exynos990/exynos9830"
DEFAULT_RP_COUNT = 23


def optional_existing_file(path):
    if path is None or str(path) == "":
        return None
    return path


def load_signer_info_file(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) != SIGNER_INFO_SIZE:
        raise ValueError(f"SignerInfo file must be 0x{SIGNER_INFO_SIZE:X} bytes, got 0x{len(data):X}")
    return data


def resolve_super_defaults(args, parser, input_layout):
    reference_path = optional_existing_file(args.super_reference)
    reference_defaults = None
    if reference_path is not None:
        if not Path(reference_path).is_file():
            if reference_path == DEFAULT_SUPER_REFERENCE:
                reference_path = None
            else:
                parser.error(f"--super-reference not found: {reference_path}")
        else:
            try:
                reference_defaults = load_super_signing_defaults(reference_path)
            except (OSError, ValueError) as e:
                parser.error(f"Could not read --super-reference {reference_path}: {e}")

    try:
        signer_info = load_signer_info_file(args.signer_info) if args.signer_info else None
    except (OSError, ValueError) as e:
        parser.error(str(e))

    if signer_info is None and reference_defaults is not None:
        signer_info = reference_defaults.signer_info
    if signer_info is None and input_layout is not None:
        try:
            signer_info = read_download_signer_info(args.input, input_layout)
        except ValueError:
            signer_info = None
    if signer_info is None:
        try:
            signer_info = read_super_embedded_signer_info(args.input)
        except ValueError:
            signer_info = None
    if signer_info is None:
        parser.error("Super signing needs SignerInfo metadata; pass --super-reference or --signer-info")

    rp_count = args.rp_cnt
    if rp_count is None and reference_defaults is not None:
        rp_count = reference_defaults.rp_count
    if rp_count is None and input_layout is not None:
        rp_count = input_layout.rp_count
    if rp_count is None:
        parser.error("--rp-cnt is required when no signed input/reference supplies a default")

    key_type = args.key_type
    if key_type is None and reference_defaults is not None:
        key_type = reference_defaults.key_type
    if key_type is None and input_layout is not None:
        key_type = input_layout.key_type
    if key_type is None:
        key_type = 0

    key_index = args.key_index
    if key_index is None and reference_defaults is not None and reference_defaults.key_index != 0:
        key_index = reference_defaults.key_index
    if key_index is None and input_layout is not None and input_layout.key_index != 0:
        key_index = input_layout.key_index
    if key_index is None:
        key_index = DEFAULT_KEY_INDEX

    return reference_path, signer_info, rp_count, args.sign_type, key_type, key_index


def resolve_download_values(args, layout):
    rp_count = args.rp_cnt if args.rp_cnt is not None else layout.rp_count
    key_type = layout.key_type if args.key_type is None else args.key_type
    key_index = args.key_index
    if key_index is None:
        key_index = layout.key_index if layout.key_index != 0 else DEFAULT_KEY_INDEX
    return rp_count, args.sign_type, key_type, key_index


def main():
    print("2024-56426 Sparse Download Signing Utility")
    print()

    parser = argparse.ArgumentParser(
        description="Sign Samsung SignerVer03 download signatures in Android sparse images"
    )
    parser.add_argument("--soc", type=str, default=DEFAULT_SOC, help=STAGE2_SOC_HELP)
    parser.add_argument("-i", "--input", required=True, help="Path to input sparse image")
    parser.add_argument("-o", "--output", required=True, help="Path to signed output sparse image")
    parser.add_argument("-k", "--key-file",
                        help=("Stage-2 private key PEM. Defaults to crecker_stage2_tee_private.pem, "
                              "or crecker_stage2_ree_private.pem for --key-type 1. "
                              "key_type 2 requires an explicit key file."))
    parser.add_argument("-r", "--rp-cnt", type=lambda x: int(x, 0), default=DEFAULT_RP_COUNT,
                        help=f"Rollback counter stored in the download signature header. Default: {DEFAULT_RP_COUNT}")
    parser.add_argument("--sign-type", type=lambda x: int(x, 0), default=SIGN_TYPE_ECDSA_NIST_P384,
                        help="Signing algorithm type. Only 4, ECDSA NIST P-384, is implemented")
    parser.add_argument("--key-type", type=lambda x: int(x, 0),
                        help="Header key type: 0 TEE, 1 REE, 2 explicit key file. Defaults to existing header")
    parser.add_argument("--key-index", type=lambda x: int(x, 0),
                        help="Header key-index/magic word. Defaults to existing header or 0x01B94633")
    parser.add_argument("--super", action="store_true",
                        help="Force Samsung super.img mode even if metadata autodetection fails")
    parser.add_argument("--super-reference", default=DEFAULT_SUPER_REFERENCE,
                        help=("Signed super.img used for default header and SignerInfo values. "
                              "Set to an empty string to disable. Default: super_signed.img"))
    parser.add_argument("--signer-info",
                        help="Raw 0x100-byte SignerInfo blob to insert for super.img signing")
    args = parser.parse_args()

    try:
        soc_config = get_soc_config(args.soc)
    except ValueError as e:
        parser.error(str(e))
    if soc_config["name"] != "exynos990":
        parser.error("Sparse download signing is implemented for Exynos 990 / Exynos9830 only")

    if args.rp_cnt is None:
        args_for_validation = argparse.Namespace(**vars(args))
        args_for_validation.rp_cnt = 0
        validate_signing_args(args_for_validation, parser)
    else:
        validate_signing_args(args, parser)

    layout = None
    try:
        layout = parse_download_signature_layout(args.input)
    except ValueError as e:
        layout_error = e
    else:
        layout_error = None

    is_super = args.super or sparse_image_has_super_metadata(args.input)
    if layout is None and not is_super:
        parser.error(str(layout_error))

    if is_super:
        reference_path, signer_info, rp_count, sign_type, key_type, key_index = resolve_super_defaults(
            args, parser, layout
        )
    else:
        reference_path = None
        signer_info = None
        rp_count, sign_type, key_type, key_index = resolve_download_values(args, layout)

    validate_signing_args(
        argparse.Namespace(rp_cnt=rp_count, sign_type=sign_type, key_type=key_type, key_index=key_index),
        parser,
    )

    try:
        private_key_path = args.key_file if args.key_file is not None else default_private_key_for_key_type(key_type)
    except ValueError as e:
        parser.error(str(e))
    private_key = load_private_key(private_key_path)
    if not is_p384_private_key(private_key):
        parser.error("The private key must be an ECDSA NIST P-384 key")

    values = rp_count, sign_type, key_type, key_index
    header = download_signature_header(*values)
    if is_super:
        layout, embedded_signer_offset = copy_with_super_signature(args.input, args.output, header, signer_info)
        payload_digest, digest = download_final_digest(args.output, layout, header)
        sig_blob = sign_digest(private_key, digest, args.soc)
        write_download_signature(args.output, layout, header, sig_blob)
        digest_path = args.output
    else:
        payload_digest, digest = download_final_digest(args.input, layout, header)
        sig_blob = sign_digest(private_key, digest, args.soc)
        copy_with_download_signature(args.input, args.output, layout, header, sig_blob)
        embedded_signer_offset = None
        digest_path = args.input

    print(f"Target SoC: {soc_config['display_name']}")
    print(f"Private key: {private_key_path}")
    print(f"Mode: {'super.img' if is_super else 'sparse download'}")
    if reference_path:
        print(f"Super defaults: {reference_path}")
    print(f"Sparse header/chunk header: 0x{layout.file_header_size:X}/0x{layout.chunk_header_size:X}")
    print(f"Signature record: 0x{layout.signature_record_offset:X}")
    print(f"Signer info:      0x{layout.signer_info_offset:X} (SignerVer0{layout.signer_version})")
    if embedded_signer_offset is not None:
        print(f"Super SignerInfo: 0x{embedded_signer_offset:X}")
        print(f"Build-id/binary:  {signer_info_quick_build_id(signer_info)} / {signer_info_binary_name(signer_info)}")
    print(f"Payload hashed:   0x{layout.payload_offset:X}..0x{layout.file_size:X} ({digest_path})")
    print(f"rp/sign/key/key-index: {values[0]}/0x{values[1]:X}/{values[2]}/0x{values[3]:X}")
    print(f"Payload SHA-512: {payload_digest.hex()}")
    print(f"Signature SHA-512: {digest.hex()}")
    print()
    print(f"Signing finished, output is at {args.output}")


if __name__ == "__main__":
    main()
