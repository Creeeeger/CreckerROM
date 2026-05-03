#!/usr/bin/env python3

import hashlib
import struct
import sys
from pathlib import Path

BLOCK_SIZE = 512
HEADER_SIZE = 16
EPBL_MAGIC = 0x68656164  # "head"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_epbl_header.py <epbl.bin>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    data = bytearray(path.read_bytes())

    if len(data) < HEADER_SIZE:
        print(f"{path}: file too small ({len(data)} bytes)", file=sys.stderr)
        return 1
    if len(data) % BLOCK_SIZE != 0:
        print(f"{path}: size {len(data)} is not {BLOCK_SIZE}-byte aligned", file=sys.stderr)
        return 1

    blocks = len(data) // BLOCK_SIZE
    hash_word0 = struct.unpack("<I", hashlib.sha512(data[HEADER_SIZE:]).digest()[:4])[0]

    # FWBL1 EPBL header expects:
    # [0x00] block_count, [0x04] expected_hash32, [0x08] "head", [0x0c] reserved.
    data[0:4] = struct.pack("<I", blocks)
    data[4:8] = struct.pack("<I", hash_word0)
    data[8:12] = struct.pack("<I", EPBL_MAGIC)
    data[12:16] = b"\x00" * 4

    path.write_bytes(data)
    print(f"{path}: blocks={blocks} hash32=0x{hash_word0:08X} magic=0x{EPBL_MAGIC:08X}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
