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
from stage2_common import (
    SIGN_TYPE_ECDSA_NIST_P384,
    SIGNER_INFO_SIZE,
    STAGE2_FOOTER_SIZE,
    STAGE2_SIGNATURE_SIZE,
    SignTarget,
    compute_digest,
    effective_verify_key_type,
    epbl_total_size_from_header,
    is_avb_wrapper_stage,
    load_pubkey_blob,
    looks_like_stage2_footer,
    normalize_stage,
    parse_avb_footer,
    parse_stage2_footer,
    read_file,
    signature_blob,
    adjacent_signer_info_offset,
    signer_info_rollback_values,
    signer_info_offset_from_avb_original,
    stage_type,
    verify_digest,
)

STAGE2_SOC_HELP = "Target SoC: exynos990/exynos9830"


def resolve_targets(stage, data, mode, requested_size, inner_mode):
    if mode == "auto":
        avb = parse_avb_footer(data)
        use_avb = is_avb_wrapper_stage(stage) and avb is not None
    else:
        use_avb = mode == "avb"
        avb = parse_avb_footer(data) if use_avb else None

    if use_avb:
        if avb is None:
            raise ValueError("AVB footer was requested but no AVB footer was found")
        if requested_size is not None:
            raise ValueError("--size is not used with AVB-wrapper verification")
        if avb.original_image_size > len(data):
            raise ValueError("AVB original_image_size points past the input file")
        if avb.original_image_size < STAGE2_FOOTER_SIZE:
            raise ValueError("AVB original_image_size is too small for a Stage-2 footer")

        # Verification mirrors signing target discovery so inner SignerVer
        # footers and AVB-original footers are checked consistently.
        targets = []
        signer_info_offset = signer_info_offset_from_avb_original(data, avb.original_image_size)
        if inner_mode == "yes":
            if signer_info_offset is None:
                raise ValueError("--inner yes requested, but no SignerVer metadata block was found")
            targets.append(SignTarget("inner", signer_info_offset))
        elif inner_mode == "auto" and signer_info_offset is not None:
            if looks_like_stage2_footer(data, signer_info_offset):
                targets.append(SignTarget("inner", signer_info_offset))

        targets.append(SignTarget("outer-avb-original", avb.original_image_size))
        return targets

    if stage == "epbl" and requested_size is None:
        total_size = epbl_total_size_from_header(data)
    else:
        total_size = requested_size if requested_size is not None else len(data)

    if total_size > len(data):
        raise ValueError("Requested signed size is larger than the input file")
    if total_size < STAGE2_FOOTER_SIZE:
        raise ValueError("Requested signed size is too small for a Stage-2 footer")

    return [SignTarget("epbl" if stage == "epbl" else "end", total_size, zero_epbl_checksum=(stage == "epbl"))]


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


def verify_target(data, target, stage, key_map, soc):
    footer = parse_stage2_footer(data, target.total_size)
    errors = []

    sig = signature_blob(data, footer)
    if sig == b"\x00" * STAGE2_SIGNATURE_SIZE:
        errors.append("signature blob is all zero")
    if footer.key_index == 0:
        errors.append("key-index/magic word is zero")
    if footer.rp_count >= 0x81:
        errors.append("rollback count is >= 0x81")
    if footer.sign_type != SIGN_TYPE_ECDSA_NIST_P384:
        errors.append(f"unsupported sign_type {footer.sign_type}; only ECDSA NIST P-384 is implemented")
    if footer.key_type > 2:
        errors.append("footer key_type is > 2")

    effective_key = effective_verify_key_type(stage, footer.key_type)
    pubkey_blob = key_map.get(effective_key)
    if pubkey_blob is None:
        errors.append(f"missing public key blob for effective key_type {effective_key}")

    digest = compute_digest(data, target.total_size, target.zero_epbl_checksum)
    signature_ok = False
    if not errors and pubkey_blob is not None:
        signature_ok = verify_digest(pubkey_blob, sig, digest, soc)
        if not signature_ok:
            errors.append("ECDSA signature check failed")

    signer_info_rp = None
    signer_info_offset = adjacent_signer_info_offset(data, target.total_size)
    if signer_info_offset is not None:
        try:
            signer_info_rp = signer_info_rollback_values(
                data[signer_info_offset:signer_info_offset + SIGNER_INFO_SIZE]
            )
            if signer_info_rp != (footer.rp_count, footer.rp_count):
                errors.append(
                    "SignerInfo rollback mismatch: "
                    f"system={signer_info_rp[0]}, kernel={signer_info_rp[1]}, "
                    f"footer={footer.rp_count}"
                )
        except ValueError as error:
            errors.append(str(error))

    return (
        footer,
        digest,
        effective_key,
        signature_ok,
        errors,
        signer_info_offset,
        signer_info_rp,
    )


def main():
    print("2024-56426 Stage-2 Verification Utility")
    print()

    parser = argparse.ArgumentParser(description="Verify EPBL and later Exynos9830 secure-boot signatures")
    parser.add_argument("--soc", type=str, default=DEFAULT_SOC, help=STAGE2_SOC_HELP)
    parser.add_argument("--stage", required=True,
                        help=("Stage name: epbl, bl2, lk, el3/el3_mon, tzsw/secureos, ldfw, "
                              "keystorage, harx, spayload, tzar, uh/plugin, modem/cp_boot/cp_main, boot, recovery, "
                              "dtbo, sboot, misc, vbmeta/vbmeta_samsung, pit"))
    parser.add_argument("-i", "--input", required=True, help="Path to signed image")
    parser.add_argument("-p", "--pub-key", help="Single public key blob to use for all key types")
    parser.add_argument("--tee-pub-key", default=DEFAULT_STAGE2_TEE_PUBKEY,
                        help=f"Stage-2 TEE public key blob. Default: {DEFAULT_STAGE2_TEE_PUBKEY}")
    parser.add_argument("--ree-pub-key", default=DEFAULT_STAGE2_REE_PUBKEY,
                        help=f"Stage-2 REE public key blob. Default: {DEFAULT_STAGE2_REE_PUBKEY}")
    parser.add_argument("--stage3-pub-key", default=DEFAULT_STAGE3_PUBKEY,
                        help=f"Stage-3 public key blob. Default: {DEFAULT_STAGE3_PUBKEY}")
    parser.add_argument("-s", "--size", type=lambda x: int(x, 0),
                        help="Signed size for normal end-footer images")
    parser.add_argument("--mode", choices=("auto", "end", "avb"), default="auto",
                        help="Footer layout. auto uses AVB-wrapper mode for known images with AVB footers")
    parser.add_argument("--inner", choices=("auto", "yes", "no"), default="auto",
                        help="For AVB-wrapper images, also verify the inner payload footer")
    args = parser.parse_args()

    try:
        soc_config = get_soc_config(args.soc)
        stage = normalize_stage(args.stage)
    except ValueError as e:
        parser.error(str(e))
    if soc_config["name"] != "exynos990":
        parser.error("Stage-2 verification is implemented for Exynos 990 / Exynos9830 only")

    key_map = load_key_map(args, args.soc)
    if not key_map:
        parser.error("Provide --pub-key or at least one of --tee-pub-key/--ree-pub-key/--stage3-pub-key")

    data = read_file(args.input)
    try:
        targets = resolve_targets(stage, data, args.mode, args.size, args.inner)
    except ValueError as e:
        parser.error(str(e))

    print(f"Target SoC: {soc_config['display_name']}")
    print(f"Stage: {stage}")
    print(f"Stage type: {stage_type(stage) if stage_type(stage) is not None else 'EPBL via BL1 wrapper'}")
    print()

    all_ok = True
    for target in targets:
        (
            footer,
            digest,
            effective_key,
            signature_ok,
            errors,
            signer_info_offset,
            signer_info_rp,
        ) = verify_target(data, target, stage, key_map, args.soc)
        all_ok = all_ok and signature_ok and not errors

        print(f"Verified {target.name}:")
        print(f"  total size: 0x{target.total_size:X}")
        print(f"  footer:     0x{footer.offset:X}")
        print(f"  signature:  0x{footer.signature_offset:X}")
        print(
            f"  rp/sign/key/key-index: {footer.rp_count}/0x{footer.sign_type:X}/{footer.key_type}/0x{footer.key_index:X}")
        print(f"  verifier key type: {effective_key}")
        if signer_info_rp is not None:
            print(
                f"  SignerInfo: 0x{signer_info_offset:X}; "
                f"system rollback={signer_info_rp[0]}, "
                f"kernel rollback={signer_info_rp[1]}"
            )
        print(f"  SHA-512: {digest.hex()}")
        print(f"  signature: {'OK' if signature_ok else 'FAIL'}")
        for error in errors:
            print(f"  error: {error}")
        print()

    if all_ok:
        print("Verification passed")
    else:
        print("Verification failed")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
