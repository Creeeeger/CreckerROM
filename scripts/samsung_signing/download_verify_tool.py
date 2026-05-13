# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import argparse

from common import DEFAULT_SOC, get_soc_config
from download_signature_common import (
    download_final_digest,
    download_signature_header,
    parse_download_signature_layout,
    read_download_signature_blob,
    read_super_embedded_signer_info,
    signer_info_binary_name,
    signer_info_quick_build_id,
    sparse_image_has_super_metadata,
    super_signer_info_output_offset,
)
from stage2_common import (
    SIGN_TYPE_ECDSA_NIST_P384,
    add_stage2_pubkey_args,
    load_stage2_key_map,
    verify_digest,
)

STAGE2_SOC_HELP = "Target SoC: exynos990/exynos9830"


def main():
    print("2024-56426 Sparse Download Verification Utility")
    print()

    parser = argparse.ArgumentParser(
        description="Verify Samsung SignerVer03 download signatures in Android sparse images"
    )
    parser.add_argument("--soc", type=str, default=DEFAULT_SOC, help=STAGE2_SOC_HELP)
    parser.add_argument("-i", "--input", required=True, help="Path to signed sparse image")
    add_stage2_pubkey_args(parser)
    args = parser.parse_args()

    try:
        soc_config = get_soc_config(args.soc)
        layout = parse_download_signature_layout(args.input)
    except ValueError as e:
        parser.error(str(e))
    if soc_config["name"] != "exynos990":
        parser.error("Sparse download verification is implemented for Exynos 990 / Exynos9830 only")

    key_map = load_stage2_key_map(args, args.soc)
    if not key_map:
        parser.error("Provide --pub-key or at least one of --tee-pub-key/--ree-pub-key/--stage3-pub-key")

    errors = []
    if layout.sign_type != SIGN_TYPE_ECDSA_NIST_P384:
        errors.append(f"unsupported sign_type {layout.sign_type}; only ECDSA NIST P-384 is implemented")
    if layout.key_type > 2:
        errors.append("header key_type is > 2")
    pubkey_blob = key_map.get(layout.key_type)
    if pubkey_blob is None:
        errors.append(f"missing public key blob for key_type {layout.key_type}")

    header = download_signature_header(layout.rp_count, layout.sign_type, layout.key_type, layout.key_index)
    payload_digest, digest = download_final_digest(args.input, layout, header)
    sig_blob = read_download_signature_blob(args.input, layout)
    signature_ok = False
    if not errors and pubkey_blob is not None:
        signature_ok = verify_digest(pubkey_blob, sig_blob, digest, args.soc)
        if not signature_ok:
            errors.append("ECDSA signature check failed")

    print(f"Target SoC: {soc_config['display_name']}")
    print(f"Sparse header/chunk header: 0x{layout.file_header_size:X}/0x{layout.chunk_header_size:X}")
    print(f"Signature record: 0x{layout.signature_record_offset:X}")
    print(f"Signer info:      0x{layout.signer_info_offset:X} (SignerVer0{layout.signer_version})")
    if sparse_image_has_super_metadata(args.input):
        try:
            super_signer_info = read_super_embedded_signer_info(args.input)
            print(f"Super SignerInfo: 0x{super_signer_info_output_offset(args.input):X}")
            print(
                f"Build-id/binary:  {signer_info_quick_build_id(super_signer_info)} / "
                f"{signer_info_binary_name(super_signer_info)}"
            )
        except ValueError as e:
            errors.append(str(e))
    print(f"Payload hashed:   0x{layout.payload_offset:X}..0x{layout.file_size:X}")
    print(f"rp/sign/key/key-index: {layout.rp_count}/0x{layout.sign_type:X}/{layout.key_type}/0x{layout.key_index:X}")
    print(f"Payload SHA-512: {payload_digest.hex()}")
    print(f"Signature SHA-512: {digest.hex()}")
    print(f"signature: {'OK' if signature_ok else 'FAIL'}")
    for error in errors:
        print(f"error: {error}")
    print()

    if signature_ok and not errors:
        print("Verification passed")
    else:
        print("Verification failed")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
