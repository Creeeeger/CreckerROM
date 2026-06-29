# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import argparse

from common import (
    DEFAULT_SOC,
    DEFAULT_STAGE3_PUBKEY,
    DEFAULT_STAGE2_REE_PUBKEY,
    DEFAULT_STAGE2_TEE_PUBKEY,
    get_soc_config,
)
from download_signature_common import (
    download_final_digest,
    download_signature_header,
    parse_download_signature_layout,
    read_download_signature_blob,
)
from stage2_common import (
    SIGN_TYPE_ECDSA_NIST_P384,
    load_pubkey_blob,
    verify_digest,
)

STAGE2_SOC_HELP = "Target SoC: exynos990/exynos9830"


def load_key_map(args, soc):
    key_map = {}
    if args.pub_key:
        blob = load_pubkey_blob(args.pub_key, soc)
        return {0: blob, 1: blob, 2: blob}
    if args.tee_pub_key:
        key_map[0] = load_pubkey_blob(args.tee_pub_key, soc)
    if args.ree_pub_key:
        key_map[1] = load_pubkey_blob(args.ree_pub_key, soc)
    if args.stage3_pub_key:
        key_map[2] = load_pubkey_blob(args.stage3_pub_key, soc)
    return key_map


def main():
    print("2024-56426 Sparse Download Verification Utility")
    print()

    parser = argparse.ArgumentParser(
        description="Verify Samsung SignerVer03 download signatures in Android sparse images"
    )
    parser.add_argument("--soc", type=str, default=DEFAULT_SOC, help=STAGE2_SOC_HELP)
    parser.add_argument("-i", "--input", required=True, help="Path to signed sparse image")
    parser.add_argument("-p", "--pub-key", help="Single public key blob to use for all key types")
    parser.add_argument("--tee-pub-key", default=DEFAULT_STAGE2_TEE_PUBKEY,
                        help=f"Stage-2 TEE public key blob. Default: {DEFAULT_STAGE2_TEE_PUBKEY}")
    parser.add_argument("--ree-pub-key", default=DEFAULT_STAGE2_REE_PUBKEY,
                        help=f"Stage-2 REE public key blob. Default: {DEFAULT_STAGE2_REE_PUBKEY}")
    parser.add_argument("--stage3-pub-key", default=DEFAULT_STAGE3_PUBKEY,
                        help=f"Stage-3 public key blob. Default: {DEFAULT_STAGE3_PUBKEY}")
    args = parser.parse_args()

    try:
        soc_config = get_soc_config(args.soc)
        layout = parse_download_signature_layout(args.input)
    except ValueError as e:
        parser.error(str(e))
    if soc_config["name"] != "exynos990":
        parser.error("Sparse download verification is implemented for Exynos 990 / Exynos9830 only")

    key_map = load_key_map(args, args.soc)
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
