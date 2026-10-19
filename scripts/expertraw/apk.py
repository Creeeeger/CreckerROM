#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later
"""Repack Expert RAW without recompiling its Android 17 resource table."""

import argparse
import struct
import zipfile
from pathlib import Path


def android15_manifest(data):
    """Change only SDK integer attributes in an Android binary XML manifest."""
    result = bytearray(data)
    kind, header, size = struct.unpack_from("<HHI", result)
    if kind != 3 or size != len(result):
        raise ValueError("Expected an Android binary XML document")
    strings = []
    changed = set()
    pos = header
    while pos < size:
        kind, chunk_header, chunk_size = struct.unpack_from("<HHI", result, pos)
        if chunk_size < chunk_header or pos + chunk_size > size:
            raise ValueError("Invalid binary XML chunk")
        if kind == 1:
            count, _, flags, start, _ = struct.unpack_from("<IIIII", result, pos + 8)
            offsets = struct.unpack_from(f"<{count}I", result, pos + chunk_header)
            for offset in offsets:
                cursor = pos + start + offset
                if flags & 0x100:
                    # UTF-8 entries have UTF-16 and UTF-8 lengths, each 1 or 2 bytes.
                    for _ in range(2):
                        first = result[cursor]
                        cursor += 2 if first & 0x80 else 1
                    end = result.index(0, cursor)
                    strings.append(result[cursor:end].decode("utf-8"))
                else:
                    length = struct.unpack_from("<H", result, cursor)[0]
                    cursor += 2
                    if length & 0x8000:
                        low = struct.unpack_from("<H", result, cursor)[0]
                        length = ((length & 0x7fff) << 16) | low
                        cursor += 2
                    strings.append(result[cursor:cursor + 2 * length].decode("utf-16le"))
        elif kind == 0x102:
            name = strings[struct.unpack_from("<I", result, pos + 20)[0]]
            attr_start, attr_size, count = struct.unpack_from("<HHH", result, pos + 24)
            for i in range(count):
                attr = pos + 16 + attr_start + i * attr_size
                key = strings[struct.unpack_from("<I", result, attr + 4)[0]]
                if (name == "uses-sdk" and key in {"minSdkVersion", "targetSdkVersion"}) or (
                    name == "manifest" and key in {"compileSdkVersion", "platformBuildVersionCode"}
                ):
                    if result[attr + 15] != 0x10:
                        raise ValueError(f"Expected integer SDK attribute: {key}")
                    before = struct.unpack_from("<I", result, attr + 16)[0]
                    if before not in {35, 37}:
                        raise ValueError(f"Unexpected {key}: {before}")
                    struct.pack_into("<I", result, attr + 16, 35)
                    changed.add(key)
        pos += chunk_size
    if not {"minSdkVersion", "targetSdkVersion"} <= changed:
        raise ValueError("SDK attributes were not found")
    return bytes(result)


def repack(source, output, dex_dir, profile, backend=None, native_files=()):
    overrides = {"assets/variation/miracle/m3q/galaxyraw-feature.xml": profile.read_bytes()}
    if backend is not None:
        with zipfile.ZipFile(backend) as legacy:
            for name in native_files:
                if not name.startswith("lib/arm64-v8a/") or not name.endswith(".so"):
                    raise ValueError(f"Unexpected native backend entry: {name}")
                overrides[name] = legacy.read(name)
    # Only include dex files supplied by the build; preserve all other entries.
    for path in dex_dir.glob("classes*.dex"):
        overrides[path.name] = path.read_bytes()
    if "classes3.dex" not in overrides:
        raise ValueError("Missing rebuilt classes3.dex")
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(output, "w") as patched:
        overrides["AndroidManifest.xml"] = android15_manifest(original.read("AndroidManifest.xml"))
        for entry in original.infolist():
            upper = entry.filename.upper()
            if upper.startswith("META-INF/") and (
                upper.endswith((".RSA", ".DSA", ".EC", ".SF")) or upper == "META-INF/MANIFEST.MF"
            ):
                continue
            data = overrides.get(entry.filename)
            patched.writestr(entry, original.read(entry.filename) if data is None else data)
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as patched:
        for name in patched.namelist():
            if name not in overrides:
                a, b = original.getinfo(name), patched.getinfo(name)
                if (a.CRC, a.file_size) != (b.CRC, b.file_size):
                    raise ValueError(f"Unintended entry change: {name}")
        if any(name not in patched.namelist() for name in overrides):
            raise ValueError("An expected patch entry was absent from the input APK")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("dex_dir", type=Path)
    parser.add_argument("profile", type=Path)
    args = parser.parse_args()
    repack(args.source, args.output, args.dex_dir, args.profile)
