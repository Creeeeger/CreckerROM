# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import argparse
import datetime
import getpass
import struct
import zlib
from pathlib import Path

from binary_io import ascii_name, read_file, read_u32
KEYSTORAGE_MAGIC = b"SLSI"
KEYSTORAGE_VERSION_20 = 0x20
KEYSTORAGE_IMAGE_LEN = 0x2000
KEY_META_OFFSET = 0x30
KEY_META_LEN = 0x10
MAX_KEY_COUNT = 7
HEADER_LEN = KEY_META_OFFSET + MAX_KEY_COUNT * KEY_META_LEN
MAX_PUBKEY_LEN = 0x420
MAX_SB_KEY_LEN = 0x20C
ECDSA_KEY_LEN = 0x88
SIGN_TYPE_ECDSA_NIST_P384 = 4
SIGN_TYPE_CUSTOM = 0xFF
VBMETA_KEY_SIZE = 1032


def write_u32(data, offset, value):
    struct.pack_into("<I", data, offset, value)


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def write_name(data, offset, name):
    encoded = name.encode("ascii")
    if len(encoded) > 8:
        raise ValueError(f"key name '{name}' is longer than 8 bytes")
    data[offset:offset + 8] = encoded.ljust(8, b"\x00")


def encode_date(value):
    if value is None:
        value = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    if len(value) != 14 or not value.isdigit():
        raise ValueError("--date must use YYYYMMDDHHMMSS")
    return int(value, 16).to_bytes(8, "little")


def encode_user(value):
    if value is None:
        value = getpass.getuser()
    return value.encode("ascii", errors="replace")[:8].ljust(8, b"\x00")


def init_v20_image(date=None, user=None):
    data = bytearray(KEYSTORAGE_IMAGE_LEN)
    data[0:4] = KEYSTORAGE_MAGIC
    write_u32(data, 0x04, KEYSTORAGE_VERSION_20)
    write_u32(data, 0x08, HEADER_LEN)
    write_u32(data, 0x0C, 0)
    data[0x10:0x18] = encode_date(date)
    data[0x18:0x20] = encode_user(user)
    write_u32(data, 0x20, 0)

    for slot in range(MAX_KEY_COUNT):
        meta = KEY_META_OFFSET + slot * KEY_META_LEN
        write_name(data, meta, "none")
        write_u32(data, meta + 8, 0)
        write_u32(data, meta + 12, 0)

    return data


def validate_v20_image(data):
    if len(data) < KEYSTORAGE_IMAGE_LEN:
        raise ValueError("template is smaller than the 0x2000 keystorage payload")
    if data[:4] != KEYSTORAGE_MAGIC:
        raise ValueError("template does not start with SLSI")
    version = read_u32(data, 0x04)
    if version != KEYSTORAGE_VERSION_20:
        raise ValueError(f"only keystorage version 0x20 is supported for 9830, got 0x{version:x}")
    header_len = read_u32(data, 0x08)
    if header_len != HEADER_LEN:
        raise ValueError(f"unexpected header_len 0x{header_len:x}, expected 0x{HEADER_LEN:x}")


def set_date_user(data, date=None, user=None):
    data[0x10:0x18] = encode_date(date)
    data[0x18:0x20] = encode_user(user)


def key_count(data):
    return read_u32(data, 0x0C)


def set_key_count(data, count):
    # body_len is the active slot count times the fixed 0x420-byte slot size.
    write_u32(data, 0x0C, count)
    write_u32(data, 0x20, count * MAX_PUBKEY_LEN)


def key_meta_offset(slot):
    return KEY_META_OFFSET + slot * KEY_META_LEN


def key_slot_offset(slot):
    return HEADER_LEN + slot * MAX_PUBKEY_LEN


def find_key_slot(data, name):
    for slot in range(MAX_KEY_COUNT):
        meta = key_meta_offset(slot)
        if ascii_name(data[meta:meta + 8]) == name:
            return slot
    return None


def allocate_key_slot(data):
    count = key_count(data)
    if count >= MAX_KEY_COUNT:
        raise ValueError("keystorage key table is full")
    return count


def normalize_ecdsa_pubkey(blob):
    # Samsung public-key files may include a 0x44-byte header prefix; the slot
    # stores only the padded P-384 coordinate block.
    if len(blob) >= 4 + ECDSA_KEY_LEN and read_u32(blob, 0) == 0x44:
        return blob[4:4 + ECDSA_KEY_LEN]
    if len(blob) >= ECDSA_KEY_LEN:
        return blob[:ECDSA_KEY_LEN]
    raise ValueError(f"ECDSA P-384 public key must contain at least 0x{ECDSA_KEY_LEN:x} bytes")


def make_secure_boot_slot(key_blob):
    slot = bytearray(MAX_PUBKEY_LEN)
    slot[:ECDSA_KEY_LEN] = normalize_ecdsa_pubkey(key_blob)
    return slot, crc32(slot[:MAX_SB_KEY_LEN])


def make_custom_slot(key_blob, key_size):
    if key_size <= 0 or key_size > MAX_PUBKEY_LEN:
        raise ValueError(f"custom key size must be 1..{MAX_PUBKEY_LEN}")
    if len(key_blob) < key_size:
        raise ValueError(f"custom key file is too short: need {key_size} bytes, got {len(key_blob)}")
    # The vbmeta slot stores raw AVB public-key bytes, so its CRC covers the
    # configured material length instead of the secure-boot key prefix length.
    slot = bytearray(MAX_PUBKEY_LEN)
    slot[:key_size] = key_blob[:key_size]
    return slot, crc32(slot[:key_size])


def set_key(data, name, slot_blob, key_index, sign_type):
    slot = find_key_slot(data, name)
    count = key_count(data)
    if slot is None:
        slot = allocate_key_slot(data)
        count = max(count, slot + 1)

    meta = key_meta_offset(slot)
    write_name(data, meta, name)
    write_u32(data, meta + 8, key_index)
    write_u32(data, meta + 12, sign_type)

    body = key_slot_offset(slot)
    data[body:body + MAX_PUBKEY_LEN] = slot_blob

    if slot + 1 > count:
        count = slot + 1
    set_key_count(data, count)
    return slot


def build_image(args):
    if args.template:
        data = bytearray(read_file(args.template))
        validate_v20_image(data)
    else:
        data = init_v20_image(args.date, args.user)

    if not args.preserve_date_user:
        set_date_user(data, args.date, args.user)

    changed = []

    if args.stage3_pub_key:
        slot_blob, key_index = make_secure_boot_slot(read_file(args.stage3_pub_key))
        slot = set_key(data, "cp_key", slot_blob, key_index, SIGN_TYPE_ECDSA_NIST_P384)
        changed.append(("cp_key", slot, key_index, SIGN_TYPE_ECDSA_NIST_P384))
    elif not args.template:
        raise ValueError("--stage3-pub-key is required when generating without --template")

    if args.vbmeta_key:
        slot_blob, key_index = make_custom_slot(read_file(args.vbmeta_key), args.vbmeta_key_size)
        slot = set_key(data, "vbmeta", slot_blob, key_index, SIGN_TYPE_CUSTOM)
        changed.append(("vbmeta", slot, key_index, SIGN_TYPE_CUSTOM))
    elif not args.template:
        raise ValueError("--vbmeta-key is required when generating without --template")

    if args.fimc_pub_key:
        slot_blob, key_index = make_secure_boot_slot(read_file(args.fimc_pub_key))
        slot = set_key(data, "fimc", slot_blob, key_index, SIGN_TYPE_ECDSA_NIST_P384)
        changed.append(("fimc", slot, key_index, SIGN_TYPE_ECDSA_NIST_P384))

    if not changed:
        raise ValueError("no key inputs were provided")

    return data, changed


def main():
    parser = argparse.ArgumentParser(
        description="Generate or patch an Exynos9830 keystorage v0x20 payload/image."
    )
    parser.add_argument("-o", "--output", required=True, help="Output keystorage image")
    parser.add_argument("--template", help="Existing keystorage.bin to patch; full AVB-wrapped images are accepted")
    parser.add_argument("--stage3-pub-key",
                        help="Stage3/CP ECDSA P-384 public key blob for key_name cp_key. "
                             "When omitted with --template, the existing cp_key slot is preserved.")
    parser.add_argument("--vbmeta-key", help="AVB public key blob for key_name vbmeta")
    parser.add_argument("--vbmeta-key-size", type=int, default=VBMETA_KEY_SIZE,
                        help=f"Number of vbmeta key bytes to store. Default: {VBMETA_KEY_SIZE}")
    parser.add_argument("--fimc-pub-key", help="FIMC ECDSA P-384 public key blob")
    parser.add_argument("--date", help="Header date as YYYYMMDDHHMMSS. Defaults to current local time")
    parser.add_argument("--user", help="Header user field, max 8 ASCII bytes. Defaults to current user")
    parser.add_argument("--preserve-date-user", action="store_true",
                        help="When patching a template, keep the existing date/user fields")
    args = parser.parse_args()

    try:
        data, changed = build_image(args)
    except ValueError as e:
        parser.error(str(e))

    Path(args.output).write_bytes(data)

    print(f"Wrote {args.output} ({len(data):#x} bytes)")
    for name, slot, key_index, sign_type in changed:
        print(f"  {name}: slot={slot} key_index=0x{key_index:08x} sign_type=0x{sign_type:x}")
    print("")
    print("Samsung footers are invalid until this image is re-signed.")
    print(
        "For a stock AVB-wrapped template, run stage2_sign_tool.py --stage keystorage next, then re-sign AVB externally.")


if __name__ == "__main__":
    main()
