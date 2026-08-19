#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

"""Prepare a stock CSC PIT's SignerInfo for the selected device model."""

import argparse
import re
from pathlib import Path

from stage2_common import (
    SIGNER_INFO_KERNEL_RP,
    SIGNER_INFO_SIZE,
    SIGNER_INFO_SYSTEM_RP,
    SIGNER_INFO_VERSION,
    STAGE2_FOOTER_SIZE,
    looks_like_stage2_footer,
    signer_info_with_rollback,
)


SIGNER_VERSION = SIGNER_INFO_VERSION

FIRMWARE_TAG = slice(0x20, 0x40)
PLATFORM_TAG = slice(0x50, 0x70)
# Backward-compatible names used by tests and callers.  LK treats these as its
# system/kernel rollback-policy slots.
SYSTEM_RP_1 = SIGNER_INFO_SYSTEM_RP
SYSTEM_RP_2 = SIGNER_INFO_KERNEL_RP
BINARY_TYPE = slice(0x90, 0x94)
FRP_TYPE = slice(0x94, 0x98)
MARKER_TYPE = slice(0x98, 0x9C)
BINARY_NAME = slice(0x9C, 0xAC)

MODEL_PATTERN = re.compile(r"^[A-Z][0-9]{3}[A-Z]$")


def decode_field(data: bytes, field: slice) -> str:
    return data[field].split(b"\0", 1)[0].decode("ascii")


def write_field(data: bytearray, field: slice, value: str) -> None:
    encoded = value.encode("ascii")
    size = field.stop - field.start
    if len(encoded) >= size:
        raise ValueError(f"{value!r} does not fit in the 0x{size:X}-byte PIT SignerInfo field")
    data[field] = encoded + b"\0" * (size - len(encoded))


def signer_info_offset(data: bytes) -> int:
    if len(data) < SIGNER_INFO_SIZE + STAGE2_FOOTER_SIZE:
        raise ValueError("PIT is too small for SignerInfo and a Stage-2 footer")
    if not looks_like_stage2_footer(data, len(data)):
        raise ValueError("PIT has no recognizable Stage-2 footer at file end")

    offset = len(data) - STAGE2_FOOTER_SIZE - SIGNER_INFO_SIZE
    if data[offset:offset + len(SIGNER_VERSION)] != SIGNER_VERSION:
        raise ValueError("PIT has no SignerVer03 block before its Stage-2 footer")
    return offset


def source_model_from_signer_info(signer_info: bytes) -> str:
    firmware = decode_field(signer_info, FIRMWARE_TAG)
    match = re.match(r"([A-Z][0-9]{3}[A-Z])", firmware)
    if match is None:
        raise ValueError(f"Cannot determine source model from firmware tag {firmware!r}")
    return match.group(1)


def replace_model(value: str, source_model: str, target_model: str, field_name: str) -> str:
    if source_model not in value:
        raise ValueError(f"PIT {field_name} {value!r} does not contain source model {source_model}")
    return value.replace(source_model, target_model, 1)


def prepare_signer_info(template: bytes, target_model: str, rollback: int) -> tuple[bytes, str]:
    target_model = target_model.upper().removeprefix("SM-")
    if MODEL_PATTERN.fullmatch(target_model) is None:
        raise ValueError(f"Invalid target model {target_model!r}")
    if not 0 <= rollback <= 999:
        raise ValueError("Rollback revision must fit the three-digit SignerInfo field")
    if len(template) != SIGNER_INFO_SIZE or not template.startswith(SIGNER_VERSION):
        raise ValueError("SignerInfo template must be one SignerVer03 block")

    result = bytearray(template)
    source_model = source_model_from_signer_info(template)
    firmware = replace_model(
        decode_field(template, FIRMWARE_TAG), source_model, target_model, "firmware tag"
    )
    platform = replace_model(
        decode_field(template, PLATFORM_TAG), source_model, target_model, "platform tag"
    )
    write_field(result, FIRMWARE_TAG, firmware)
    write_field(result, PLATFORM_TAG, platform)

    result = bytearray(signer_info_with_rollback(bytes(result), rollback))

    result[BINARY_TYPE] = b"usr\0"
    result[FRP_TYPE] = b"frp\0"
    result[MARKER_TYPE] = b"mrk\0"
    write_field(result, BINARY_NAME, "pit")
    return bytes(result), source_model


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Prepare stock CSC PIT SignerInfo for Samsung Stage-2 re-signing"
    )
    parser.add_argument("-i", "--input", required=True, help="Stock CSC .pit file")
    parser.add_argument("-o", "--output", required=True, help="Prepared .pit output")
    parser.add_argument("--target-model", required=True, help="Selected device model, for example G985F")
    parser.add_argument("--rollback", required=True, type=lambda value: int(value, 0))
    args = parser.parse_args()

    try:
        data = bytearray(Path(args.input).read_bytes())
        offset = signer_info_offset(data)
        prepared, source_model = prepare_signer_info(
            bytes(data[offset:offset + SIGNER_INFO_SIZE]),
            args.target_model,
            args.rollback,
        )
        data[offset:offset + SIGNER_INFO_SIZE] = prepared
        Path(args.output).write_bytes(data)
    except (OSError, ValueError) as error:
        parser.error(str(error))

    target_model = args.target_model.upper().removeprefix("SM-")
    print(f"PIT signed extent: 0x{len(data):X}")
    print(f"SignerInfo:       0x{offset:X} (SignerVer03)")
    print(f"Source model:     {source_model}")
    print(f"Target model:     {target_model}")
    print(f"Firmware tag:     {decode_field(prepared, FIRMWARE_TAG)}")
    print(f"Platform tag:     {decode_field(prepared, PLATFORM_TAG)}")
    print(f"System rollback:  {args.rollback}")
    print("Binary type/name: usr / pit")


if __name__ == "__main__":
    main()
