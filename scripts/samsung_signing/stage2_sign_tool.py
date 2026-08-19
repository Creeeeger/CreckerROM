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
from stage2_common import (
    DEFAULT_KEY_INDEX,
    SIGN_TYPE_ECDSA_NIST_P384,
    STAGE2_FOOTER_SIZE,
    STAGE2_SIGNATURE_SIZE,
    SignTarget,
    compute_digest,
    default_key_type,
    effective_verify_key_type,
    epbl_total_size_from_header,
    load_private_key,
    looks_like_stage2_footer,
    is_avb_wrapper_stage,
    normalize_stage,
    parse_avb_footer,
    parse_stage2_footer,
    read_file,
    sign_digest,
    signer_info_offset_from_avb_original,
    stage_type,
    update_adjacent_signer_info_rollback,
    update_epbl_checksum,
    update_epbl_header,
    write_file,
    write_stage2_footer_header,
)

STAGE2_SOC_HELP = "Target SoC: exynos990/exynos9830"


def default_private_key_for_key_type(key_type):
    if key_type == 2:
        return DEFAULT_STAGE3_PRIVATE_KEY
    if key_type == 1:
        return DEFAULT_STAGE2_REE_PRIVATE_KEY
    return DEFAULT_STAGE2_TEE_PRIVATE_KEY


def default_or_existing_key_type(stage, existing, key_type_arg):
    if key_type_arg is not None:
        return key_type_arg
    stage_default = default_key_type(stage)
    if stage_default == 2:
        return stage_default
    return existing.key_type if existing is not None else stage_default


def resolve_private_key_path(args, stage, data, targets):
    if args.key_file is not None:
        return args.key_file

    target = targets[0]
    existing = None
    if looks_like_stage2_footer(data, target.total_size):
        existing = parse_stage2_footer(data, target.total_size)
    key_type = default_or_existing_key_type(stage, existing, args.key_type)
    return default_private_key_for_key_type(key_type)


def create_output_buffer(input_data, size, append_footer):
    if size is not None and append_footer:
        raise ValueError("--size and --append-footer cannot be used together")

    if append_footer:
        output_size = len(input_data) + STAGE2_FOOTER_SIZE
    elif size is not None:
        output_size = size
    else:
        output_size = len(input_data)

    if output_size < len(input_data):
        raise ValueError("Output size cannot be smaller than input size")
    if output_size < STAGE2_FOOTER_SIZE:
        raise ValueError("Output size is too small for a Stage-2 footer")

    output = bytearray(output_size)
    output[:len(input_data)] = input_data
    return output


def resolve_end_target(stage, data, requested_size):
    if stage == "epbl" and requested_size is None:
        return epbl_total_size_from_header(data)
    return requested_size if requested_size is not None else len(data)


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
            raise ValueError("--size is not used with AVB-wrapper signing")
        if avb.original_image_size > len(data):
            raise ValueError("AVB original_image_size points past the input file")
        if avb.original_image_size < STAGE2_FOOTER_SIZE:
            raise ValueError("AVB original_image_size is too small for a Stage-2 footer")

        # This signs Samsung footer bytes inside the AVB original payload. The
        # caller must re-sign AVB afterward if the image still carries AVB.
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

    total_size = resolve_end_target(stage, data, requested_size)
    if total_size > len(data):
        raise ValueError("Resolved signed size is larger than the output buffer")
    if stage == "epbl":
        return [SignTarget("epbl", total_size, zero_epbl_checksum=True, update_epbl_checksum=True)]
    return [SignTarget("end", total_size)]


def select_footer_values(stage, data, target, rp_count, sign_type, key_type_arg, key_index_arg):
    existing = None
    if looks_like_stage2_footer(data, target.total_size):
        existing = parse_stage2_footer(data, target.total_size)

    key_type = key_type_arg
    if key_type is None:
        key_type = default_or_existing_key_type(stage, existing, key_type_arg)

    key_index = key_index_arg
    if key_index is None:
        key_index = existing.key_index if existing is not None and existing.key_index != 0 else DEFAULT_KEY_INDEX

    return rp_count, sign_type, key_type, key_index


def sign_target(data, target, private_key, stage, rp_count, sign_type, key_type, key_index, soc):
    footer = write_stage2_footer_header(data, target.total_size, rp_count, sign_type, key_type, key_index)
    digest = compute_digest(data, target.total_size, target.zero_epbl_checksum)
    sig_blob = sign_digest(private_key, digest, soc)
    data[footer.signature_offset:footer.signature_offset + STAGE2_SIGNATURE_SIZE] = sig_blob

    checksum_digest = None
    if target.update_epbl_checksum:
        checksum_digest = update_epbl_checksum(data, target.total_size)

    effective_key = effective_verify_key_type(stage, footer.key_type)
    return footer, digest, checksum_digest, effective_key


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
    print("2024-56426 Stage-2 Signing Utility")
    print()

    parser = argparse.ArgumentParser(description="Sign EPBL and later Exynos9830 boot-chain images")
    parser.add_argument("--soc", type=str, default=DEFAULT_SOC, help=STAGE2_SOC_HELP)
    parser.add_argument("--stage", required=True,
                        help=("Stage name: epbl, bl2, lk, el3/el3_mon, tzsw/secureos, ldfw, "
                              "keystorage, harx, spayload, tzar, uh/plugin, modem/cp_boot/cp_main, boot, recovery, "
                              "dtbo, sboot, misc, vbmeta/vbmeta_samsung"))
    parser.add_argument("-i", "--input", required=True, help="Path to input image")
    parser.add_argument("-o", "--output", required=True, help="Path to signed output image")
    parser.add_argument("-k", "--key-file",
                        help=("Stage-2 private key PEM. Defaults to crecker_stage2_tee_private.pem, "
                              "crecker_stage2_ree_private.pem for key_type 1, or "
                              "crecker_stage3_private.pem for key_type 2"))
    parser.add_argument("-r", "--rp-cnt", type=lambda x: int(x, 0), required=True,
                        help="Rollback counter stored in the Stage-2 footer")
    parser.add_argument("--sign-type", type=lambda x: int(x, 0), default=SIGN_TYPE_ECDSA_NIST_P384,
                        help="Signing algorithm type. Only 4, ECDSA NIST P-384, is implemented")
    parser.add_argument("--key-type", type=lambda x: int(x, 0),
                        help="Footer key type: 0 TEE, 1 REE, 2 Stage-3. Defaults to the stage policy or existing footer")
    parser.add_argument("--key-index", type=lambda x: int(x, 0),
                        help="Footer key-index/magic word. Defaults to existing footer or 0x01B94633")
    parser.add_argument("-s", "--size", type=lambda x: int(x, 0),
                        help="Final signed size for normal end-footer images")
    parser.add_argument("--append-footer", action="store_true",
                        help="Append a new 0x210-byte Stage-2 footer to the input")
    parser.add_argument("--mode", choices=("auto", "end", "avb"), default="auto",
                        help="Footer layout. auto uses AVB-wrapper mode for known images with AVB footers")
    parser.add_argument("--inner", choices=("auto", "yes", "no"), default="auto",
                        help="For AVB-wrapper images, also sign the inner payload footer")
    args = parser.parse_args()

    try:
        soc_config = get_soc_config(args.soc)
        stage = normalize_stage(args.stage)
    except ValueError as e:
        parser.error(str(e))
    if soc_config["name"] != "exynos990":
        parser.error("Stage-2 signing is implemented for Exynos 990 / Exynos9830 only")

    validate_args(args, parser)

    input_data = read_file(args.input)
    data = create_output_buffer(input_data, args.size, args.append_footer)
    if stage == "epbl":
        epbl_size = resolve_end_target(stage, data, args.size if args.size is not None else len(data))
        update_epbl_header(data, epbl_size)

    targets = resolve_targets(stage, data, args.mode, args.size, args.inner)
    signer_info_offsets = []
    for target in targets:
        offset = update_adjacent_signer_info_rollback(
            data,
            target.total_size,
            args.rp_cnt,
        )
        if offset is not None and offset not in signer_info_offsets:
            signer_info_offsets.append(offset)
    private_key_path = resolve_private_key_path(args, stage, data, targets)
    private_key = load_private_key(private_key_path)
    if not isinstance(getattr(private_key, "curve", None), ec.SECP384R1):
        parser.error("The private key must be an ECDSA NIST P-384 key")

    print(f"Target SoC: {soc_config['display_name']}")
    print(f"Stage: {stage}")
    print(f"Stage type: {stage_type(stage) if stage_type(stage) is not None else 'EPBL via BL1 wrapper'}")
    print(f"Private key: {private_key_path}")
    for offset in signer_info_offsets:
        print(
            f"SignerInfo rollback: system={args.rp_cnt} kernel={args.rp_cnt} "
            f"at 0x{offset:X}"
        )
    print()

    for target in targets:
        values = select_footer_values(
            stage, data, target, args.rp_cnt, args.sign_type, args.key_type, args.key_index
        )
        footer, digest, checksum_digest, effective_key = sign_target(data, target, private_key, stage, *values,
                                                                     args.soc)
        print(f"Signed {target.name}:")
        print(f"  total size: 0x{target.total_size:X}")
        print(f"  footer:     0x{footer.offset:X}")
        print(f"  signature:  0x{footer.signature_offset:X}")
        print(
            f"  rp/sign/key/key-index: {footer.rp_count}/0x{footer.sign_type:X}/{footer.key_type}/0x{footer.key_index:X}")
        print(f"  verifier key type: {effective_key}")
        print(f"  SHA-512: {digest.hex()}")
        if checksum_digest is not None:
            print(f"  EPBL header checksum: {checksum_digest[:4].hex()}")
        print()

    avb = parse_avb_footer(data)
    if avb is not None and args.mode != "end":
        print("Note: secure-boot signature bytes changed inside an AVB image.")
        print("      This tool does not re-sign AVB vbmeta.")
        print()

    write_file(args.output, data)
    print(f"Signing finished, output is at {args.output}")


if __name__ == "__main__":
    main()
