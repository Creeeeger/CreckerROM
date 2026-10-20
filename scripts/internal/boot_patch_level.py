#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later
"""Set boot-header patch metadata before Samsung and AVB signing."""

import argparse
from datetime import date
from pathlib import Path
import re
import struct
import sys


def validate_patch_level(value: str) -> str:
    if value == "preserve":
        return value
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise ValueError("patch level must be YYYY-MM-DD or preserve")
    parsed = date.fromisoformat(value)
    if not 2000 <= parsed.year <= 2127:
        raise ValueError("patch year does not fit the Android boot header")
    return value


def header_patch(path: Path) -> tuple[int, int] | None:
    with path.open("rb") as image:
        header = image.read(1660)
    if header.startswith(b"VNDRBOOT"):
        # Vendor boot headers have no os_version / patch-level field.
        return None
    if not header.startswith(b"ANDROID!") or len(header) < 44:
        raise ValueError(f"{path}: invalid Android boot header")
    version = struct.unpack_from("<I", header, 40)[0]
    sizes = {0: 1632, 1: 1648, 2: 1660, 3: 1580, 4: 1584}
    if version not in sizes or len(header) < sizes[version]:
        raise ValueError(f"{path}: unsupported or truncated boot header v{version}")
    offset = 44 if version <= 2 else 16
    packed = struct.unpack_from("<I", header, offset)[0]
    if version == 4:
        # GKI v4 requires os_version=0 and carries version data in AVB props.
        if packed != 0:
            raise ValueError(f"{path}: GKI v4 requires os_version=0")
        return None
    return offset, packed


def update_images(directory: Path, patch_level: str, verify: bool = False) -> None:
    validate_patch_level(patch_level)
    if patch_level == "preserve":
        print("Preserving boot image patch metadata")
        return
    patch = date.fromisoformat(patch_level)
    encoded = ((patch.year - 2000) << 4) | patch.month
    changes = []
    for name in ("boot", "recovery", "init_boot", "vendor_boot"):
        path = directory / f"{name}.img"
        if not path.exists():
            continue
        fields = header_patch(path)
        if fields is None:
            print(f"{path.name}: no boot-header patch field; using AVB metadata")
            continue
        offset, original = fields
        expected = (original & ~0x7FF) | encoded
        if verify and original != expected:
            raise ValueError(f"{path.name}: boot-header patch level is not {patch_level[:7]}")
        changes.append((path, offset, expected))
    # Validate all inputs before changing any image. Signatures must be rebuilt
    # by the caller after this four-byte header edit.
    for path, offset, expected in changes:
        if not verify:
            with path.open("r+b") as image:
                image.seek(offset)
                image.write(struct.pack("<I", expected))
        print(f"{path.name}: boot-header patch level {patch_level[:7]}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--patch-level", required=True)
    parser.add_argument("--images-dir", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    try:
        value = validate_patch_level(args.patch_level)
        if args.images_dir is None:
            print(value)
        else:
            if not args.images_dir.is_dir():
                raise ValueError(f"image directory does not exist: {args.images_dir}")
            update_images(args.images_dir, value, args.verify)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
