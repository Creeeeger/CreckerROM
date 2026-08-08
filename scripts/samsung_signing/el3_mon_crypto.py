#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: Umer Uddin
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

"""Exynos9830 EL3 monitor AES-CBC region helpers."""

import struct

from aes_cbc import select_aes_backend

DEFAULT_KEY = bytes.fromhex(
    "9D2DDC5410E693757A74EA025D07173703CCC65A7B5C7B768B099F5FAF065082"
)
DEFAULT_IV = bytes.fromhex("C421FA6FC8DB9CB22AE2B43BB5671D7F")
DEFAULT_LOAD_ADDR = 0xBFE80000
DEFAULT_PTR_ENCRYPTION_INFO_OFF = 0x0004
DEFAULT_REGION_START_FIELD_OFF = 0x000C
DEFAULT_REGION_END_FIELD_OFF = 0x0010


def _read_u32_le(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise ValueError(f"u32 read out of range at offset 0x{offset:X}")
    return struct.unpack_from("<I", data, offset)[0]


def _read_u64_le(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 8 > len(data):
        raise ValueError(f"u64 read out of range at offset 0x{offset:X}")
    return struct.unpack_from("<Q", data, offset)[0]


def resolve_el3_mon_region(image: bytes) -> tuple[int, int]:
    encryption_info_offset = _read_u64_le(image, DEFAULT_PTR_ENCRYPTION_INFO_OFF)
    start_pointer = _read_u32_le(
        image,
        encryption_info_offset + DEFAULT_REGION_START_FIELD_OFF,
    )
    end_pointer = _read_u32_le(
        image,
        encryption_info_offset + DEFAULT_REGION_END_FIELD_OFF,
    )
    if start_pointer < DEFAULT_LOAD_ADDR or end_pointer < DEFAULT_LOAD_ADDR:
        raise ValueError(
            "EL3 monitor region pointer is below the load address: "
            f"start=0x{start_pointer:X} end=0x{end_pointer:X}"
        )

    start = start_pointer - DEFAULT_LOAD_ADDR
    end = end_pointer - DEFAULT_LOAD_ADDR
    if start < 0 or start >= end or end > len(image):
        raise ValueError(
            f"invalid EL3 monitor region 0x{start:X}-0x{end:X} "
            f"for image size 0x{len(image):X}"
        )
    if (end - start) % 16:
        raise ValueError("EL3 monitor AES-CBC region is not block aligned")
    return start, end


def crypt_el3_mon_region(image: bytes, *, decrypt: bool) -> tuple[bytes, str, int, int]:
    start, end = resolve_el3_mon_region(image)
    backend_name, aes_cbc = select_aes_backend()
    output = bytearray(image)
    output[start:end] = aes_cbc(
        bytes(output[start:end]),
        DEFAULT_KEY,
        DEFAULT_IV,
        decrypt,
    )
    return bytes(output), backend_name, start, end
