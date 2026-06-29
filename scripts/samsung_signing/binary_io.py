#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import struct
from pathlib import Path


def read_file(path):
    return Path(path).read_bytes()


def read_u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def write_u32(value):
    return struct.pack("<I", value)


def ascii_name(raw):
    return raw.split(b"\x00", 1)[0].decode("ascii", errors="replace")
