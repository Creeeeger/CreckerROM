# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import argparse

from cryptography.hazmat.primitives.asymmetric import ec

from common import (
    DEFAULT_SOC,
    DEFAULT_STAGE3_PRIVATE_KEY,
    DEFAULT_STAGE2_REE_PRIVATE_KEY,
    DEFAULT_STAGE2_TEE_PRIVATE_KEY,
    get_soc_config,
)
from download_signature_common import (
    copy_with_download_signature,
    download_final_digest,
    download_signature_header,
    parse_download_signature_layout,
    select_download_header_values,
)
from stage2_common import (
    SIGN_TYPE_ECDSA_NIST_P384,
    load_private_key,
    sign_digest,
)

STAGE2_SOC_HELP = "Target SoC: exynos990/exynos9830"


def default_private_key_for_key_type(key_type):
    if key_type == 2:
        return DEFAULT_STAGE3_PRIVATE_KEY
    if key_type == 1:
        return DEFAULT_STAGE2_REE_PRIVATE_KEY
    return DEFAULT_STAGE2_TEE_PRIVATE_KEY


def validate_args(args, parser):
    if args.rp_cnt < 0 or args.rp_cnt >= 0x81:
        parser.error("--rp-cnt must be in range 0..0x80")
    if args.sign_type != SIGN_TYPE_ECDSA_NIST_P384:
        parser.error("Only sign_type 4 (ECDSA NIST P-384) is implemented")
    if args.key_type is not None and not 0 <= args.key_type <= 2:
        parser.error("--key-type must be 0, 1, or 2")
    if args.key_index is not None and args.key_index == 0:
        parser.error("--key-index must be non-zero")


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
                              "crecker_stage2_ree_private.pem for --key-type 1, or "
                              "crecker_stage3_private.pem for --key-type 2"))
    parser.add_argument("-r", "--rp-cnt", type=lambda x: int(x, 0), required=True,
                        help="Rollback counter stored in the download signature header")
    parser.add_argument("--sign-type", type=lambda x: int(x, 0), default=SIGN_TYPE_ECDSA_NIST_P384,
                        help="Signing algorithm type. Only 4, ECDSA NIST P-384, is implemented")
    parser.add_argument("--key-type", type=lambda x: int(x, 0),
                        help="Header key type: 0 TEE, 1 REE, 2 Stage-3. Defaults to existing header")
    parser.add_argument("--key-index", type=lambda x: int(x, 0),
                        help="Header key-index/magic word. Defaults to existing header or 0x01B94633")
    args = parser.parse_args()

    try:
        soc_config = get_soc_config(args.soc)
    except ValueError as e:
        parser.error(str(e))
    if soc_config["name"] != "exynos990":
        parser.error("Sparse download signing is implemented for Exynos 990 / Exynos9830 only")

    validate_args(args, parser)

    try:
        layout = parse_download_signature_layout(args.input)
    except ValueError as e:
        parser.error(str(e))

    key_type = layout.key_type if args.key_type is None else args.key_type
    private_key_path = args.key_file if args.key_file is not None else default_private_key_for_key_type(key_type)
    private_key = load_private_key(private_key_path)
    if not isinstance(getattr(private_key, "curve", None), ec.SECP384R1):
        parser.error("The private key must be an ECDSA NIST P-384 key")

    values = select_download_header_values(
        layout, args.rp_cnt, args.sign_type, args.key_type, args.key_index
    )
    header = download_signature_header(*values)
    payload_digest, digest = download_final_digest(args.input, layout, header)
    sig_blob = sign_digest(private_key, digest, args.soc)
    copy_with_download_signature(args.input, args.output, layout, header, sig_blob)

    print(f"Target SoC: {soc_config['display_name']}")
    print(f"Private key: {private_key_path}")
    print(f"Sparse header/chunk header: 0x{layout.file_header_size:X}/0x{layout.chunk_header_size:X}")
    print(f"Signature record: 0x{layout.signature_record_offset:X}")
    print(f"Signer info:      0x{layout.signer_info_offset:X} (SignerVer0{layout.signer_version})")
    print(f"Payload hashed:   0x{layout.payload_offset:X}..0x{layout.file_size:X}")
    print(f"rp/sign/key/key-index: {values[0]}/0x{values[1]:X}/{values[2]}/0x{values[3]:X}")
    print(f"Payload SHA-512: {payload_digest.hex()}")
    print(f"Signature SHA-512: {digest.hex()}")
    print()
    print(f"Signing finished, output is at {args.output}")


if __name__ == "__main__":
    main()
