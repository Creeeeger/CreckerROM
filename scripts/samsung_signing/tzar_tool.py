#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import argparse
import hashlib
import json
import shutil
import struct
import tempfile
from pathlib import Path

from apply_binary_patches import patch_file
from common import (
    DEFAULT_SOC,
    DEFAULT_STAGE2_TEE_PRIVATE_KEY,
    DEFAULT_STAGE2_TEE_PUBKEY,
    get_soc_config,
)
from cryptography.hazmat.primitives.asymmetric import ec
from stage2_common import (
    DEFAULT_KEY_INDEX,
    SIGN_TYPE_ECDSA_NIST_P384,
    STAGE2_FOOTER_SIZE,
    STAGE2_SIGNATURE_SIZE,
    compute_digest,
    effective_verify_key_type,
    load_private_key,
    load_pubkey_blob,
    sign_digest,
    signature_blob,
    verify_digest,
    write_stage2_footer_header,
)

OUTER_LZ4_MAGIC = b"\x04\x22\x4d\x18"
LEGACY_LZ4_MAGIC = b"\x02\x21\x4c\x18"
TZAR_MAGIC = b"\x7f\xa5TA"
TZAR_HEADER_SIZE = 0x10
MANIFEST_NAME = "tzar_manifest.json"
FILES_DIR = "files"
RAW_DIR = "_raw"


from tzar_archive import (
    FILES_DIR,
    MANIFEST_NAME,
    RAW_DIR,
    default_keys_dir,
    find_userboot_hash_table,
    lz4_compress,
    parse_startup_tzar,
    read_input_image,
    safe_output_path,
    startup_hash_table,
    write_manifest,
)

def extract_command(args):
    out_dir = Path(args.output)
    files_dir = out_dir / FILES_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    files_dir.mkdir(parents=True, exist_ok=True)

    image_info = read_input_image(args.input, args.container)
    startup = image_info["startup"]
    records = parse_startup_tzar(startup)

    for record in records:
        dest = safe_output_path(files_dir, record["path"])
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(record["payload"])

    if args.save_raw:
        raw_dir = out_dir / RAW_DIR
        raw_dir.mkdir(parents=True, exist_ok=True)
        (raw_dir / "startup.tzar").write_bytes(startup)
        if image_info["wrapped"] is not None:
            (raw_dir / "tzar.img").write_bytes(image_info["wrapped"])

    manifest = write_manifest(out_dir, image_info, startup, records)
    print(f"Extracted {len(records)} TZAR records to {files_dir}")
    print(f"Manifest: {out_dir / MANIFEST_NAME}")
    if manifest["wrapped_image"]["stage2_footer"] is not None:
        footer = manifest["wrapped_image"]["stage2_footer"]
        print(
            "Stage-2 footer: "
            f"size=0x{footer['total_size']:X} rp={footer['rp_count']} "
            f"sign=0x{footer['sign_type']:X} key={footer['key_type']} "
            f"key-index=0x{footer['key_index']:X}"
        )


def load_manifest(folder):
    path = Path(folder) / MANIFEST_NAME
    if not path.is_file():
        raise FileNotFoundError(f"Missing manifest: {path}")
    return json.loads(path.read_text())


def build_startup_tzar(folder, manifest):
    files_dir = Path(folder) / FILES_DIR
    header = bytearray.fromhex(manifest["startup"]["magic"])
    header += bytearray.fromhex(manifest["startup"]["version_raw"])
    header += b"\x00\x00\x00\x00"
    header += struct.pack("<I", manifest["startup"]["unknown_0c"])
    if len(header) != TZAR_HEADER_SIZE:
        raise ValueError("Manifest startup header is invalid")

    output = bytearray(header)
    # Preserve manifest order because userboot hash-table indices are derived
    # from the original startup.tzar record sequence.
    for record in sorted(manifest["records"], key=lambda item: item["index"]):
        archive_path = record["path"]
        src = safe_output_path(files_dir, archive_path)
        if not src.is_file():
            raise FileNotFoundError(f"Missing extracted TZAR member: {src}")
        payload = src.read_bytes()
        path_raw = archive_path.encode("utf-8") + b"\x00"
        output += struct.pack("<II", len(path_raw), len(payload))
        output += path_raw
        output += payload

    struct.pack_into("<I", output, 8, len(output))
    return bytes(output)


def manifest_footer_defaults(manifest):
    footer = manifest.get("wrapped_image", {}).get("stage2_footer")
    if not footer:
        return None
    return footer


def resolve_signing_defaults(args, manifest):
    footer = manifest_footer_defaults(manifest)
    rp_count = args.rp_cnt
    if rp_count is None:
        rp_count = footer["rp_count"] if footer else 23

    key_type = args.key_type
    if key_type is None:
        key_type = footer["key_type"] if footer else 0

    key_index = args.key_index
    if key_index is None:
        key_index = footer["key_index"] if footer and footer["key_index"] else DEFAULT_KEY_INDEX

    signed_size = args.signed_size
    if signed_size is None:
        signed_size = manifest.get("wrapped_image", {}).get("size")
    return rp_count, key_type, key_index, signed_size


def align_up(value, alignment):
    return (value + alignment - 1) // alignment * alignment


def sign_tzar_image(unsigned_wrapped, signed_size, args, manifest):
    rp_count, key_type, key_index, manifest_signed_size = resolve_signing_defaults(args, manifest)
    if signed_size is None:
        signed_size = manifest_signed_size
    min_signed_size = len(unsigned_wrapped) + STAGE2_FOOTER_SIZE
    if signed_size is None:
        signed_size = align_up(min_signed_size, args.grow_align)
    if min_signed_size > signed_size:
        if not args.allow_grow:
            raise ValueError(
                f"Rebuilt compressed TZAR needs 0x{min_signed_size:X} bytes including footer, "
                f"but signed size is 0x{signed_size:X}. Use --allow-grow or --signed-size."
            )
        signed_size = align_up(min_signed_size, args.grow_align)

    # Preserve the wrapped signed size when possible so bootloader offsets that
    # point past the compressed payload remain valid.
    data = bytearray(signed_size)
    data[:len(unsigned_wrapped)] = unsigned_wrapped
    private_key = load_private_key(args.key_file)
    if not isinstance(getattr(private_key, "curve", None), ec.SECP384R1):
        raise ValueError("TZAR Stage-2 signing key must be ECDSA NIST P-384")

    footer = write_stage2_footer_header(
        data,
        signed_size,
        rp_count,
        SIGN_TYPE_ECDSA_NIST_P384,
        key_type,
        key_index,
    )
    digest = compute_digest(data, signed_size)
    sig_blob = sign_digest(private_key, digest, args.soc)
    data[footer.signature_offset:footer.signature_offset + STAGE2_SIGNATURE_SIZE] = sig_blob

    verify_ok = None
    if args.pub_key:
        pubkey_blob = load_pubkey_blob(args.pub_key, args.soc)
        verify_ok = verify_digest(pubkey_blob, signature_blob(data, footer), digest, args.soc)
        if not verify_ok:
            raise ValueError("Post-signature verification failed")

    return bytes(data), footer, digest, verify_ok


def pack_command(args):
    folder = Path(args.input)
    manifest = load_manifest(folder)
    if manifest.get("format") != "teegris-startup-tzar-v1":
        raise ValueError("Unsupported TZAR manifest format")

    startup = build_startup_tzar(folder, manifest)
    legacy_lz4 = lz4_compress(startup, legacy=True)
    unsigned_wrapped = struct.pack("<I", len(startup)) + legacy_lz4

    if args.write_startup:
        Path(args.write_startup).write_bytes(startup)
    if args.write_unsigned:
        Path(args.write_unsigned).write_bytes(unsigned_wrapped)

    if args.no_sign:
        final_wrapped = unsigned_wrapped
        footer = None
        digest = None
        verify_ok = None
    else:
        final_wrapped, footer, digest, verify_ok = sign_tzar_image(unsigned_wrapped, args.signed_size, args, manifest)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    write_outer = args.outer_lz4 == "yes" or (args.outer_lz4 == "auto" and output.suffix == ".lz4")
    if write_outer:
        output.write_bytes(lz4_compress(final_wrapped, legacy=False))
    else:
        output.write_bytes(final_wrapped)

    print(f"Startup TZAR size: 0x{len(startup):X}")
    print(f"Legacy-LZ4 payload size: 0x{len(legacy_lz4):X}")
    print(f"Wrapped TZAR output: {output} ({'outer LZ4' if write_outer else 'raw tzar.img'})")
    if footer is not None:
        print(f"Signed size: 0x{footer.total_size:X}")
        print(
            f"Stage-2 footer: off=0x{footer.offset:X} sig=0x{footer.signature_offset:X} "
            f"rp={footer.rp_count} sign=0x{footer.sign_type:X} key={footer.key_type} "
            f"key-index=0x{footer.key_index:X}"
        )
        print(f"Verifier key type: {effective_verify_key_type('tzar', footer.key_type)}")
        print(f"SHA-512: {digest.hex()}")
        if verify_ok is not None:
            print("Post-signature verification: OK")


def patch_member_command(args):
    temp_dir = None
    if args.work_dir:
        work_dir = Path(args.work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)
    else:
        temp_dir = tempfile.mkdtemp(prefix="tzar-member-patch-")
        work_dir = Path(temp_dir)

    extract_dir = work_dir / "extract"
    if extract_dir.exists():
        shutil.rmtree(extract_dir)

    try:
        extract_command(
            argparse.Namespace(
                input=args.input,
                output=extract_dir,
                container=args.container,
                save_raw=True,
            )
        )
        member_path = safe_output_path(extract_dir / FILES_DIR, args.member)
        if not member_path.is_file():
            raise FileNotFoundError(f"Missing extracted TZAR member: {member_path}")
        patch_file(
            member_path,
            args.patch_table,
            target_label=f"TZAR member {args.member}",
        )

        pack_args = argparse.Namespace(**vars(args))
        pack_args.input = extract_dir
        pack_command(pack_args)
        print(f"Updated TZAR written to {args.output}")
        if args.keep_work:
            print(f"Kept work dir: {work_dir}")
    finally:
        if temp_dir and not args.keep_work:
            shutil.rmtree(temp_dir, ignore_errors=True)


def info_command(args):
    image_info = read_input_image(args.input, args.container)
    records = parse_startup_tzar(image_info["startup"])
    print(f"Input: {args.input}")
    print(f"Container: {image_info['container']}")
    print(f"Startup size: 0x{len(image_info['startup']):X}")
    print(f"Records: {len(records)}")
    if image_info["footer"] is not None:
        footer = image_info["footer"]
        print(
            f"Stage-2 footer: size=0x{footer.total_size:X} off=0x{footer.offset:X} "
            f"rp={footer.rp_count} sign=0x{footer.sign_type:X} key={footer.key_type} "
            f"key-index=0x{footer.key_index:X}"
        )
    for record in records:
        print(
            f"{record['index']:02d} 0x{record['size']:08X} "
            f"{record['payload_sha256'][:16]} {record['startup_hash'][:16]} {record['path']}"
        )


def patch_tzsw_hashes_command(args):
    image_info = read_input_image(args.tzar, args.container)
    records = parse_startup_tzar(image_info["startup"])
    expected_table = startup_hash_table(records)

    # After a TZAR member changes, the clear TZSW userboot hash table must be
    # updated to the hashes from the rebuilt tzar.img.
    tzsw_path = Path(args.input)
    tzsw = bytearray(tzsw_path.read_bytes())
    table_offset, table_size = find_userboot_hash_table(tzsw, len(records))
    old_table = bytes(tzsw[table_offset:table_offset + table_size])

    changed = []
    for record in records:
        start = record["index"] * hashlib.sha256().digest_size
        end = start + hashlib.sha256().digest_size
        old_hash = old_table[start:end]
        new_hash = expected_table[start:end]
        if old_hash != new_hash:
            changed.append((record, old_hash, new_hash))

    tzsw[table_offset:table_offset + table_size] = expected_table
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(tzsw)

    print(
        f"Patched TZSW userboot TZAR hash table: "
        f"off=0x{table_offset:X} size=0x{table_size:X} entries={len(records)} changed={len(changed)}"
    )
    for record, old_hash, new_hash in changed:
        print(
            f"  {record['index']:02d} {record['path']} "
            f"{old_hash.hex()[:16]} -> {new_hash.hex()[:16]}"
        )


def parse_int(value):
    return int(value, 0)


def add_signing_args(parser):
    keys_dir = default_keys_dir()
    parser.add_argument("--soc", default=DEFAULT_SOC, help="Target SoC. Default: exynos990")
    parser.add_argument("--keys-dir", type=Path, default=keys_dir,
                        help=f"Directory containing crecker Stage-2 keys. Default: {keys_dir}")
    parser.add_argument("-k", "--key-file", type=Path,
                        help="Stage-2 TEE private key PEM. Defaults to <keys-dir>/crecker_stage2_tee_private.pem")
    parser.add_argument("-p", "--pub-key", type=Path,
                        help="Stage-2 TEE public key blob for post-sign verification. "
                             "Defaults to <keys-dir>/crecker_stage2_tee_pubkey.bin when present")
    parser.add_argument("-r", "--rp-cnt", type=parse_int,
                        help="Rollback counter. Defaults to the extracted footer value or 23")
    parser.add_argument("--key-type", type=parse_int,
                        help="Footer key type. Defaults to the extracted footer value or 0")
    parser.add_argument("--key-index", type=parse_int,
                        help="Footer key index. Defaults to the extracted footer value or 0x01B94633")


def add_repack_args(parser):
    parser.add_argument("--signed-size", type=parse_int,
                        help="Signed wrapped TZAR size. Defaults to manifest wrapped-image size")
    parser.add_argument("--allow-grow", action="store_true",
                        help="Allow signed-size to grow if the new legacy-LZ4 payload no longer fits")
    parser.add_argument("--grow-align", type=parse_int, default=0x1000,
                        help="Alignment used with --allow-grow or when no size exists. Default: 0x1000")
    parser.add_argument("--outer-lz4", choices=("auto", "yes", "no"), default="auto",
                        help="Write standard LZ4 frame container. auto enables this for .lz4 outputs")
    parser.add_argument("--no-sign", action="store_true",
                        help="Only rebuild the unsigned wrapped TZAR. This is not bootable as a modified BL TZAR")
    parser.add_argument("--write-startup", help="Optional path for the rebuilt decompressed startup.tzar")
    parser.add_argument("--write-unsigned",
                        help="Optional path for the unsigned wrapped tzar.img before footer signing")
    add_signing_args(parser)


def normalize_pack_args(args):
    get_soc_config(args.soc)
    if args.key_file is None:
        args.key_file = args.keys_dir / DEFAULT_STAGE2_TEE_PRIVATE_KEY
    if args.pub_key is None:
        candidate = args.keys_dir / DEFAULT_STAGE2_TEE_PUBKEY
        args.pub_key = candidate if candidate.is_file() else None
    if not args.no_sign and not args.key_file.is_file():
        raise FileNotFoundError(f"Missing private key: {args.key_file}")


def main():
    parser = argparse.ArgumentParser(description="Extract and rebuild Samsung TEEgris startup TZAR images")
    subparsers = parser.add_subparsers(dest="command", required=True)

    extract = subparsers.add_parser("extract", help="Extract a tzar.img/tzar.img.lz4/startup.tzar to a folder")
    extract.add_argument("-i", "--input", required=True, help="Input tzar.img.lz4, tzar.img, or decompressed TZAR")
    extract.add_argument("-o", "--output", required=True, help="Output extraction folder")
    extract.add_argument("--container", choices=("auto", "outer-lz4", "wrapped", "startup"), default="auto")
    extract.add_argument("--save-raw", action=argparse.BooleanOptionalAction, default=True,
                         help="Also save raw startup.tzar and wrapped tzar.img under _raw/")
    extract.set_defaults(func=extract_command)

    pack = subparsers.add_parser("pack", help="Rebuild, sign, and optionally outer-LZ4 a TZAR extraction folder")
    pack.add_argument("-i", "--input", required=True, help="Extraction folder containing tzar_manifest.json")
    pack.add_argument("-o", "--output", required=True, help="Output tzar.img or tzar.img.lz4")
    add_repack_args(pack)
    pack.set_defaults(func=pack_command)

    patch_member = subparsers.add_parser(
        "patch-member",
        help="Extract TZAR, patch one member from a TSV table, rebuild, and sign",
    )
    patch_member.add_argument("-i", "--input", required=True, help="Input tzar.img.lz4 or raw tzar.img")
    patch_member.add_argument("-o", "--output", required=True, help="Output tzar.img.lz4 or raw tzar.img")
    patch_member.add_argument("--member", required=True,
                              help="Member path inside startup.tzar, for example /sbin/root_task")
    patch_member.add_argument("--patch-table", type=Path, required=True,
                              help="Byte-exact TSV patch table for the extracted member")
    patch_member.add_argument("--container", choices=("auto", "outer-lz4", "wrapped", "startup"), default="auto")
    patch_member.add_argument("--work-dir", help="Optional persistent extraction work directory")
    patch_member.add_argument("--keep-work", action="store_true", help="Keep temporary extraction directory")
    add_repack_args(patch_member)
    patch_member.set_defaults(func=patch_member_command)

    info = subparsers.add_parser("info", help="Print TZAR records and Stage-2 footer metadata")
    info.add_argument("-i", "--input", required=True, help="Input tzar.img.lz4, tzar.img, or decompressed TZAR")
    info.add_argument("--container", choices=("auto", "outer-lz4", "wrapped", "startup"), default="auto")
    info.set_defaults(func=info_command)

    patch_tzsw = subparsers.add_parser(
        "patch-tzsw-hashes",
        help="Patch the userboot startup.tzar object hash table inside a decrypted/clear tzsw.img",
    )
    patch_tzsw.add_argument("-i", "--input", required=True, help="Input decrypted/clear tzsw.img")
    patch_tzsw.add_argument("-o", "--output", required=True, help="Output patched tzsw.img")
    patch_tzsw.add_argument("--tzar", required=True, help="Signed or unsigned tzar.img used as the hash source")
    patch_tzsw.add_argument("--container", choices=("auto", "outer-lz4", "wrapped", "startup"), default="auto")
    patch_tzsw.set_defaults(func=patch_tzsw_hashes_command)

    args = parser.parse_args()
    if args.command in ("pack", "patch-member"):
        normalize_pack_args(args)
    args.func(args)


if __name__ == "__main__":
    main()
