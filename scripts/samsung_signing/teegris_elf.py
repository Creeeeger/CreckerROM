#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
"""Read and validate the ELF metadata used by the stock TEE compatibility adapters."""

import hashlib
import os
import struct
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from parse_tas import parse_elf
from tzar_archive import LEGACY_LZ4_MAGIC, lz4_decompress, parse_startup_tzar, read_input_image


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_records(path):
    data = Path(path).read_bytes()
    # Newer donor images have uncompressed/compressed sizes before legacy LZ4.
    if len(data) >= 16 and data[8:12] == LEGACY_LZ4_MAGIC:
        usize, wrapped_size, block_size = struct.unpack_from('<III', data[:8] + data[12:16])
        if wrapped_size != block_size + 8 or 8 + wrapped_size > len(data):
            raise ValueError('Invalid TZAR compressed-size header')
        startup = lz4_decompress(data[8:8 + wrapped_size], expected_size=usize)
    else:
        startup = read_input_image(path, 'auto')['startup']
    records = parse_startup_tzar(startup)
    paths = [r['path'] for r in records]
    if len(paths) != len(set(paths)):
        raise ValueError('Duplicate TZAR member paths')
    return records


def ta_payload(data):
    if data.startswith(b'\x7fELF'):
        return data
    if data[:4] in (b'SEC2', b'SEC3', b'SEC4') and data[8:12] == b'\x7fELF':
        length = int.from_bytes(data[4:8], 'big')
        if length < 64 or 8 + length > len(data):
            raise ValueError('Invalid TA payload length')
        return data[8:8 + length]
    raise ValueError('Expected a TA ELF or plaintext SEC container')


def elf_metadata(data):
    elf = parse_elf(data, 0)
    if elf['elf_class'] != 'ELF64' or elf['machine'] != 'AArch64' or data[5] != 1:
        raise ValueError('Expected a little-endian ELF64 AArch64 secure library')
    sections = elf['sections']
    dynstr = sections['.dynstr']
    strings = data[dynstr['offset']:dynstr['offset'] + dynstr['size']]

    def string(offset):
        if not 0 <= offset < len(strings):
            raise ValueError('Invalid dynamic string offset')
        end = strings.find(b'\0', offset)
        if end < 0:
            raise ValueError('Unterminated dynamic string')
        return strings[offset:end].decode('utf-8')

    needed, soname = [], None
    dynamic = sections['.dynamic']
    if dynamic['size'] % 16:
        raise ValueError('Invalid ELF64 dynamic-section size')
    for offset in range(dynamic['offset'], dynamic['offset'] + dynamic['size'], 16):
        tag, value = struct.unpack_from('<QQ', data, offset)
        if tag == 0:
            break
        if tag == 1:
            needed.append(string(value))
        elif tag == 14:
            soname = string(value)
    for name in needed:
        checked = name
        if not checked or '/' in checked or checked in ('.', '..'):
            raise ValueError('Unexpected dependency name: ' + name)
    exports, imports = set(), set()
    dynsym = sections['.dynsym']
    if dynsym['size'] % 24:
        raise ValueError('Invalid ELF64 dynamic-symbol size')
    for offset in range(dynsym['offset'], dynsym['offset'] + dynsym['size'], 24):
        name, info, other, index, _, _ = struct.unpack_from('<IBBHQQ', data, offset)
        if not name:
            continue
        bind = info >> 4
        if index and bind in (1, 2) and (other & 3) in (0, 3):
            exports.add(string(name))
        elif not index and bind == 1:
            imports.add(string(name))
    versions = sorted({s.decode() for s in strings.split(b'\0') if s.startswith(b'TEEGRIS_')})
    return {'needed': needed, 'soname': soname, 'versions': versions,
            'exports': exports, 'strong_imports': imports, 'interpreter': elf['interp']}


def properties(data):
    section = parse_elf(data, 0)['sections'].get('TA_property')
    if section is None:
        return None
    return data[section['offset']:section['offset'] + section['size']]


def repack_ta(container, elf):
    old = ta_payload(container)
    if container[:4] != b'SEC3' or container[8:8 + len(old)] != old:
        raise ValueError('Expected the pinned plaintext SEC3 FKeyMaster container')
    # Intermediate payload edit; callers must authenticate the result before
    # installing it. adapt_fkeymaster_stock_abi signs the final SEC3 package.
    return container[:4] + struct.pack('>I', len(elf)) + elf + container[8 + len(old):]


def write_file(path, data):
    """Replace an output only after validation, preserving its file mode."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(data)
            temporary.flush()
            os.chmod(temporary_path, mode)
            os.replace(temporary_path, path)
        finally:
            temporary_path.unlink(missing_ok=True)
