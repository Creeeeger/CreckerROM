# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import argparse
import struct
import zlib
from pathlib import Path

from binary_io import ascii_name
from common import DEFAULT_SOC, SOC_HELP, get_soc_config
from stage2_common import (
    parse_avb_footer,
    parse_stage2_footer,
    read_file,
    read_u32,
    signer_info_offset_from_avb_original,
    looks_like_stage2_footer,
)

SLSI_MAGIC = b"SLSI"
SLSI_HEADER_SIZE = 0x30
SLSI_ENTRY_SIZE = 0x10
SLSI_V20_PAYLOAD_SIZE = 0x2000
SLSI_V30_PAYLOAD_SIZE = 0x4000
SLSI_MAX_PUBKEY_LEN = 0x420
SLSI_MAX_SB_KEY_LEN = 0x20C
SLSI_MAX_SIGN_TYPES = 9
SLSI_WHITELIST_ENTRY_SIZE = 0x10
SLSI_V30_WHITELIST_COUNT = 12
SAMSUNG_ECDSA_PUBKEY_HEADER_VALUE = 0x44


def fmt_hex(value):
    if value is None:
        return "n/a"
    return f"0x{value:x}"


def trimmed_len(blob):
    return len(blob.rstrip(b"\x00"))


def count_nonzero(blob):
    return sum(1 for b in blob if b != 0)


def crc32(blob):
    return zlib.crc32(blob) & 0xFFFFFFFF


def keystorage_payload_size(version):
    return SLSI_V30_PAYLOAD_SIZE if version >= 0x30 else SLSI_V20_PAYLOAD_SIZE


def key_meta_offset(version):
    if version >= 0x30:
        return SLSI_HEADER_SIZE + SLSI_WHITELIST_ENTRY_SIZE * SLSI_V30_WHITELIST_COUNT
    return SLSI_HEADER_SIZE


def key_index_length(slot, sign_type):
    # Samsung ECDSA slots use a fixed secure-boot key prefix for key_index CRC;
    # custom slots use the actual non-zero key material length.
    if 0 <= sign_type < SLSI_MAX_SIGN_TYPES:
        return min(SLSI_MAX_SB_KEY_LEN, len(slot))
    return trimmed_len(slot)


def safe_filename(name):
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in name) or "key"


def iter_key_slots(data):
    if len(data) < SLSI_HEADER_SIZE:
        raise ValueError("input is too small for an SLSI header")

    version = read_u32(data, 0x04)
    header_len = read_u32(data, 0x08)
    key_count = read_u32(data, 0x0C)
    body_len = read_u32(data, 0x20)
    meta_offset = key_meta_offset(version)

    if key_count == 0:
        return []
    if body_len % key_count != 0:
        raise ValueError("cannot infer slot size from key_count/body_len")

    slot_size = body_len // key_count
    slots = []
    for index in range(key_count):
        entry_offset = meta_offset + index * SLSI_ENTRY_SIZE
        slot_offset = header_len + index * slot_size
        slot_end = slot_offset + slot_size
        if entry_offset + SLSI_ENTRY_SIZE > len(data) or slot_end > len(data):
            raise ValueError(f"slot {index} points past EOF")

        sign_type = read_u32(data, entry_offset + 12)
        slot = data[slot_offset:slot_end]
        slots.append({
            "index": index,
            "name": ascii_name(data[entry_offset:entry_offset + 8]),
            "key_index": read_u32(data, entry_offset + 8),
            "sign_type": sign_type,
            "slot": slot,
            "slot_offset": slot_offset,
            "slot_size": slot_size,
            "indexed_len": key_index_length(slot, sign_type),
        })

    return slots


def nonzero_ranges(data, limit):
    ranges = []
    start = None
    for offset, value in enumerate(data[:limit]):
        if value and start is None:
            start = offset
        elif not value and start is not None:
            ranges.append((start, offset))
            start = None
    if start is not None:
        ranges.append((start, min(limit, len(data))))
    return ranges


def classify_p384_slot(slot, soc):
    soc_config = get_soc_config(soc)
    coord_size = soc_config["ecdsa_coord_size"]
    field_size = soc_config["ecdsa_field_size"]
    prefix_size = field_size * 2
    pad_size = field_size - coord_size

    if len(slot) < prefix_size:
        return None

    x_pad = slot[:pad_size]
    x = slot[pad_size:field_size]
    y_pad = slot[field_size:field_size + pad_size]
    y = slot[field_size + pad_size:prefix_size]
    rest = slot[prefix_size:]

    if (
            x_pad == b"\x00" * pad_size
            and y_pad == b"\x00" * pad_size
            and rest == b"\x00" * len(rest)
            and x != b"\x00" * coord_size
            and y != b"\x00" * coord_size
    ):
        return {
            "prefix_size": prefix_size,
            "x_offset": pad_size,
            "y_offset": field_size + pad_size,
            "coord_size": coord_size,
        }

    return None


def classify_slot(slot, soc):
    p384 = classify_p384_slot(slot, soc)
    if p384:
        return (
            "P-384 public key prefix "
            f"(x +0x{p384['x_offset']:x}, y +0x{p384['y_offset']:x}, "
            f"prefix 0x{p384['prefix_size']:x})"
        )

    used = trimmed_len(slot)
    if used >= 0x400 or slot[:4] == b"\x00\x00\x10\x00":
        return "AVB/RSA-style key material (inferred)"

    if used == 0:
        return "empty"

    return "data"


def print_stage2_footer(data, label, total_size):
    if total_size is None or total_size > len(data):
        print(f"{label}: no valid total size")
        return

    if not looks_like_stage2_footer(data, total_size):
        print(f"{label}: no valid Samsung Stage-2 footer at total {fmt_hex(total_size)}")
        return

    footer = parse_stage2_footer(data, total_size)
    print(
        f"{label}: footer={fmt_hex(footer.offset)} digest_end={fmt_hex(footer.digest_end)} "
        f"rp={footer.rp_count} sign=0x{footer.sign_type:x} key_type={footer.key_type} "
        f"key_index=0x{footer.key_index:x}"
    )


def parse_keystorage(data, soc, show_ranges):
    if len(data) < SLSI_HEADER_SIZE:
        raise ValueError("input is too small for an SLSI header")

    magic = data[:4]
    version = read_u32(data, 0x04)
    header_len = read_u32(data, 0x08)
    key_count = read_u32(data, 0x0C)
    body_len = read_u32(data, 0x20)
    meta_offset = key_meta_offset(version)
    slot_size = None
    if key_count and body_len % key_count == 0:
        slot_size = body_len // key_count

    print("SLSI header")
    print(f"  magic: {magic!r}")
    print(f"  version: {fmt_hex(version)}")
    print(f"  header_len: {fmt_hex(header_len)}")
    print(f"  key_count: {key_count}")
    print(f"  date_bcd_hex: 0x{int.from_bytes(data[0x10:0x18], 'little'):014x}")
    print(f"  date_raw: {data[0x10:0x18].hex(' ')}")
    print(f"  user: {ascii_name(data[0x18:0x20])!r}")
    print(f"  body_len: {fmt_hex(body_len)}")
    if version >= 0x30:
        print(f"  whitelist_target_num: {read_u32(data, 0x24)}")
        print(f"  whitelist_offset: {fmt_hex(SLSI_HEADER_SIZE)}")
    print(f"  key_meta_offset: {fmt_hex(meta_offset)}")
    print(f"  inferred_slot_size: {fmt_hex(slot_size)}")

    if magic != SLSI_MAGIC:
        print("  warning: magic is not SLSI")

    if header_len < meta_offset or header_len > len(data):
        table_count = 0
    else:
        table_count = (header_len - meta_offset) // SLSI_ENTRY_SIZE

    print("")
    print("Key metadata")
    for index in range(table_count):
        offset = meta_offset + index * SLSI_ENTRY_SIZE
        name = ascii_name(data[offset:offset + 8])
        key_index = read_u32(data, offset + 8)
        sign_type = read_u32(data, offset + 12)
        active = "active" if index < key_count else "inactive"
        print(
            f"  [{index}] off={fmt_hex(offset)} name={name!r} "
            f"key_index=0x{key_index:08x} sign_type=0x{sign_type:08x} {active}"
        )

    if slot_size is None:
        print("")
        print("Slots: cannot infer slot size from active count and slot area size")
    else:
        print("")
        print("Slots")
        for index in range(key_count):
            entry_offset = meta_offset + index * SLSI_ENTRY_SIZE
            slot_offset = header_len + index * slot_size
            slot_end = slot_offset + slot_size
            if slot_end > len(data):
                print(f"  [{index}] slot points past EOF: {fmt_hex(slot_offset)}..{fmt_hex(slot_end - 1)}")
                continue

            name = ascii_name(data[entry_offset:entry_offset + 8])
            key_index = read_u32(data, entry_offset + 8)
            sign_type = read_u32(data, entry_offset + 12)
            slot = data[slot_offset:slot_end]
            used = trimmed_len(slot)
            index_len = key_index_length(slot, sign_type)
            indexed = slot[:index_len]
            slot_crc = crc32(indexed) if indexed else 0
            crc_match = "match" if slot_crc == key_index else "no-match"
            last_used = slot_offset + used - 1 if used else None

            print(
                f"  [{index}] {name!r} range={fmt_hex(slot_offset)}..{fmt_hex(slot_end - 1)} "
                f"used={fmt_hex(used)} indexed={fmt_hex(index_len)} "
                f"last_used={fmt_hex(last_used)} nonzero={count_nonzero(slot)}"
            )
            print(
                f"      kind: {classify_slot(slot, soc)}\n"
                f"      crc32(indexed)=0x{slot_crc:08x} ({crc_match} vs key_index)"
            )

    print("")
    print("Samsung/AVB wrapper")
    payload_size = keystorage_payload_size(version)
    print_stage2_footer(data, f"  inner-{fmt_hex(payload_size)}",
                        payload_size if len(data) >= payload_size else None)

    avb = parse_avb_footer(data)
    if avb:
        print(
            f"  avb_footer: original_image_size={fmt_hex(avb.original_image_size)} "
            f"vbmeta_offset={fmt_hex(avb.vbmeta_offset)} vbmeta_size={fmt_hex(avb.vbmeta_size)}"
        )
        signer_info_offset = signer_info_offset_from_avb_original(data, avb.original_image_size)
        print(f"  signer_info_offset: {fmt_hex(signer_info_offset)}")
        print_stage2_footer(data, "  outer-avb-original", avb.original_image_size)
    else:
        print("  avb_footer: not found")

    print_stage2_footer(data, "  file-size", len(data))

    if show_ranges:
        print("")
        print(f"Nonzero ranges in first {fmt_hex(payload_size)} bytes")
        for start, end in nonzero_ranges(data, min(payload_size, len(data))):
            print(f"  {fmt_hex(start)}..{fmt_hex(end - 1)} len={fmt_hex(end - start)}")


def extract_keys(data, output_dir, soc):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("")
    print(f"Extracted keys to {output_dir}")
    for key in iter_key_slots(data):
        name = safe_filename(key["name"])
        slot = key["slot"]
        sign_type = key["sign_type"]
        p384 = classify_p384_slot(slot, soc)

        if 0 <= sign_type < SLSI_MAX_SIGN_TYPES and p384:
            blob = struct.pack("<I", SAMSUNG_ECDSA_PUBKEY_HEADER_VALUE) + slot[:p384["prefix_size"]]
            suffix = "publickey"
        else:
            used = key["indexed_len"] or trimmed_len(slot)
            blob = slot[:used]
            suffix = "bin"

        path = output_dir / f"{name}.{suffix}"
        path.write_bytes(blob)
        print(
            f"  {key['name']}: {path} len={fmt_hex(len(blob))} "
            f"sign_type=0x{sign_type:x} key_index=0x{key['key_index']:08x}"
        )


def main():
    parser = argparse.ArgumentParser(
        description="Inspect the Exynos9830 SLSI keystorage.bin layout without modifying the image."
    )
    parser.add_argument("-i", "--input", required=True, help="Path to keystorage.bin")
    parser.add_argument("--soc", default=DEFAULT_SOC, help=SOC_HELP)
    parser.add_argument("--ranges", action="store_true",
                        help="Print nonzero byte ranges in the first 0x2000 bytes")
    parser.add_argument("--extract-dir",
                        help="Extract active key slots into this directory")
    args = parser.parse_args()

    path = Path(args.input)
    data = read_file(path)
    print(f"Input: {path} ({fmt_hex(len(data))} bytes)")
    print("")
    parse_keystorage(data, args.soc, args.ranges)
    if args.extract_dir:
        extract_keys(data, args.extract_dir, args.soc)


if __name__ == "__main__":
    main()
