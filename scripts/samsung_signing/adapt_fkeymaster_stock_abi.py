#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
"""Adapt the pinned FKeyMaster ELF to the existing G986B secure libraries."""

import argparse
import struct
import tempfile
from pathlib import Path

from apply_binary_patches import patch_file
from teegris_elf import elf_metadata, read_records, sha256, ta_payload, repack_ta, properties, write_file
from parse_tas import parse_elf

SOURCE_TA_SHA256 = '3568db8c24ae4e75ff1a1f98837964612db590293ada19cccfc969e8ac722fa9'
SOURCE_ELF_SHA256 = '2899ffc6fbfcf41cb7f3b6809694e1d6f78708048c23905fa0d4c2c7c8852552'
STOCK_LIBRARY_SHA256 = {
    'libtzsl.so': '533c53c2a63ef43f14987625b83fe5ffd79afc7f658786893f80bacdb637686f',
    'libteesl.so': 'f9e6c923d4c436ad7d645315c9ca4292b6bc9316ae19a87985d37c9e1dc3cf5e',
    'libpthread.so': 'f67d49e556fadd175d79b66353164e0f935144a3df03ecf033f860c1fb86eae0',
    'libc++.so': 'bfad51324bee8e20cda8564918d3ef710d3c65d670a1724e3ba12af537ae2575',
    'libscrypto.so': 'a4308b5553ad9b45d68ca73f6c99a758c3911acfb248f90cb9a6e0479667eb04',
}
ALIASES = {'libgpapi.so': 'libteesl.so', 'libtee_ext.so': 'libteesl.so'}
PATCH_TABLE = Path(__file__).resolve().parents[2] / 'security/samsung/patches/fkeymaster_stock_stdio.tsv'
MEMREF_PATCH_TABLE = PATCH_TABLE.with_name('fkeymaster_stock_memrefs.tsv')


def elf_hash(text):
    value = 0
    for byte in text.encode():
        value = (value << 4) + byte
        high = value & 0xf0000000
        if high:
            value ^= high >> 24
        value &= ~high
    return value & 0xffffffff


def versioned_symbols(data):
    """Decode GNU import-provider bindings and exported symbol versions."""
    sections = parse_elf(data, 0)['sections']
    strings = sections['.dynstr']
    names = data[strings['offset']:strings['offset'] + strings['size']]

    def string(offset):
        end = names.find(b'\0', offset)
        if not 0 <= offset < len(names) or end < 0:
            raise ValueError('Invalid GNU version string')
        return names[offset:end].decode()

    def chain(section, relative, fmt):
        size = struct.calcsize(fmt)
        if relative < 0 or relative + size > section['size']:
            raise ValueError('Invalid GNU version chain')
        return struct.unpack_from(fmt, data, section['offset'] + relative)

    needs, definitions = {}, {}
    for key in ('.gnu.version_r', '.gnu.version_d'):
        section = sections.get(key)
        if not section or not section['size']:
            continue
        relative = 0
        while True:
            if key == '.gnu.version_r':
                version, count, provider, auxiliary, following = chain(section, relative, '<HHIII')
                auxiliary += relative
                for _ in range(count):
                    hash_value, flags, index, name, next_aux = chain(section, auxiliary, '<IHHII')
                    if hash_value != elf_hash(string(name)):
                        raise ValueError('GNU version-need hash mismatch')
                    needs[index & 0x7fff] = (string(provider), string(name))
                    auxiliary += next_aux
            else:
                version, flags, index, count, hash_value, auxiliary, following = chain(section, relative, '<HHHHIII')
                name, next_aux = chain(section, relative + auxiliary, '<II')
                definitions[index & 0x7fff] = string(name)
            if version != 1:
                raise ValueError('Unsupported GNU symbol-version format')
            if not following:
                break
            relative += following

    imports, exports = [], set()
    symbols = sections['.dynsym']
    versions = sections.get('.gnu.version')
    if symbols['size'] % 24:
        raise ValueError('Invalid ELF64 dynamic-symbol size')
    for index in range(symbols['size'] // 24):
        name, info, other, section, value, size = struct.unpack_from('<IBBHQQ', data, symbols['offset'] + index * 24)
        version = chain(versions, index * 2, '<H')[0] & 0x7fff if versions else 1
        if not name:
            continue
        if not section and info >> 4 == 1:
            if version >= 2 and version not in needs:
                raise ValueError('Missing GNU import-provider binding')
            imports.append((string(name), needs.get(version)))
        elif section and info >> 4 in (1, 2) and other & 3 in (0, 3):
            if version >= 2 and version not in definitions:
                raise ValueError('Missing GNU export-version definition')
            exports.add((string(name), definitions.get(version)))
    return imports, exports


def adapt(container):
    if sha256(container) != SOURCE_TA_SHA256:
        raise ValueError('FKeyMaster source container differs from the pinned S721B donor')
    original = ta_payload(container)
    if sha256(original) != SOURCE_ELF_SHA256:
        raise ValueError('FKeyMaster source ELF hash mismatch')
    data = bytearray(original)
    elf = parse_elf(data, 0)
    sections = elf['sections']
    dynstr = sections['.dynstr']

    def string(offset):
        start = dynstr['offset'] + offset
        end = data.find(0, start, dynstr['offset'] + dynstr['size'])
        if end < 0:
            raise ValueError('Unterminated ELF dynamic string')
        return bytes(data[start:end]).decode()

    dynamic = sections['.dynamic']
    tags = []
    needed_offsets = {}
    bind_now = False
    for offset in range(dynamic['offset'], dynamic['offset'] + dynamic['size'], 16):
        tag, value = struct.unpack_from('<QQ', data, offset)
        if tag == 0:
            break
        if tag == 1:
            needed_offsets[string(value)] = value
            if string(value) in ALIASES:
                continue
        # The stock linker recognizes DT_BIND_NOW, but ignores the donor's
        # newer DT_FLAGS/DF_BIND_NOW spelling. Preserve eager relocation.
        if tag == 30:
            if value != 8:
                raise ValueError('Unexpected FKeyMaster DT_FLAGS')
            tag, value = 24, 0
            bind_now = True
        tags.append((tag, value))
    if not set(ALIASES) <= needed_offsets.keys() or 'libteesl.so' not in needed_offsets:
        raise ValueError('Unexpected FKeyMaster dependencies')
    if not bind_now:
        raise ValueError('Missing donor DF_BIND_NOW')
    rebuilt = b''.join(struct.pack('<QQ', *entry) for entry in tags) + bytes(16)
    if len(rebuilt) > dynamic['size']:
        raise ValueError('Dynamic section does not have room')
    data[dynamic['offset']:dynamic['offset'] + dynamic['size']] = rebuilt.ljust(dynamic['size'], b'\0')

    # Retain each version index used by .gnu.version and its relocations, while
    # binding GPAPI/TEE extension imports to the real stock libteesl provider.
    versions = sections['.gnu.version_r']
    offset = versions['offset']
    renamed_files = []
    auxiliary_offsets = []
    version_names = set()
    while True:
        version, count, file_name, auxiliary, following = struct.unpack_from('<HHIII', data, offset)
        if version != 1:
            raise ValueError('Unsupported GNU version-need format')
        name = string(file_name)
        if name in ALIASES:
            struct.pack_into('<I', data, offset + 4, needed_offsets[ALIASES[name]])
            renamed_files.append(name)
        aux = offset + auxiliary
        for index in range(count):
            hash_value, flags, other, name_offset, next_aux = struct.unpack_from('<IHHII', data, aux)
            if string(name_offset) != 'TEEGRIS_5':
                raise ValueError('Unexpected FKeyMaster symbol version')
            auxiliary_offsets.append(aux)
            version_names.add(name_offset)
            if index + 1 < count and not next_aux:
                raise ValueError('Truncated GNU version-need auxiliary chain')
            aux += next_aux
        if not following:
            break
        offset += following
        if offset >= versions['offset'] + versions['size']:
            raise ValueError('Invalid GNU version-need chain')
    if sorted(renamed_files) != sorted(ALIASES):
        raise ValueError('Missing GPAPI/TEE extension version bindings')
    for name_offset in version_names:
        start = dynstr['offset'] + name_offset
        data[start:start + 9] = b'TEEGRIS_4'
    for aux in auxiliary_offsets:
        struct.pack_into('<I', data, aux, elf_hash('TEEGRIS_4'))

    # Reuse a removed dependency's string slot for fprintf. The undefined
    # dynamic symbol remains in the same slot, retaining all relocation indices.
    fprintf_name = needed_offsets['libgpapi.so']
    start = dynstr['offset'] + fprintf_name
    data[start:start + 8] = b'fprintf\0'
    dynsym = sections['.dynsym']
    found = []
    for offset in range(dynsym['offset'], dynsym['offset'] + dynsym['size'], 24):
        name, info, other, section, value, size = struct.unpack_from('<IBBHQQ', data, offset)
        if name and string(name) == 'fwrite':
            if section or info >> 4 != 1:
                raise ValueError('Unexpected fwrite symbol definition')
            struct.pack_into('<I', data, offset, fprintf_name)
            found.append(offset)
    if len(found) != 1:
        raise ValueError('Expected one undefined fwrite symbol')
    # Renaming a dynsym entry also changes its SysV lookup bucket. GNU hash
    # covers only the unchanged defined exports; its table stays untouched.
    hashes = sections['.hash']
    buckets_count, symbols_count = struct.unpack_from('<II', data, hashes['offset'])
    if not buckets_count or symbols_count != dynsym['size'] // 24 or hashes['size'] != 8 + 4 * (buckets_count + symbols_count):
        raise ValueError('Unexpected FKeyMaster SysV hash layout')
    buckets, chains = [0] * buckets_count, [0] * symbols_count
    for index in range(1, symbols_count):
        name = struct.unpack_from('<I', data, dynsym['offset'] + index * 24)[0]
        bucket = elf_hash(string(name)) % buckets_count
        chains[index] = buckets[bucket]
        buckets[bucket] = index
    struct.pack_into('<' + 'I' * (buckets_count + symbols_count), data, hashes['offset'] + 8, *buckets, *chains)
    if data[0x3fb8:0x3fb8 + 26] != b'Memory allocation failed\n\0':
        raise ValueError('Allocation failure literal changed')
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / 'fkeymaster.elf'
        path.write_bytes(data)
        patch_file(path, PATCH_TABLE, target_label='FKeyMaster stock stdio calls')
        patch_file(path, MEMREF_PATCH_TABLE, target_label='FKeyMaster stock memref widths')
        data = bytearray(path.read_bytes())
    if len(data) != len(original) or properties(data) != properties(original):
        raise ValueError('TA size or properties changed')
    decoded = elf_metadata(data)
    if decoded['needed'] != [n for n in elf_metadata(original)['needed'] if n not in ALIASES]:
        raise ValueError('Stock dependency adaptation failed')
    if decoded['versions'] != ['TEEGRIS_4']:
        raise ValueError('Stock version adaptation failed')
    if 'fwrite' in decoded['strong_imports'] or 'fprintf' not in decoded['strong_imports']:
        raise ValueError('stdio import adaptation failed')
    return repack_ta(container, bytes(data))


def verify_stock_bindings(container, stock_tzar):
    metadata = elf_metadata(ta_payload(container))
    stock = {r['path']: r['payload'] for r in read_records(stock_tzar)}
    pending = list(metadata['needed'])
    selected = {}
    while pending:
        name = pending.pop()
        if name in selected:
            continue
        path = '/lib64/' + name
        if path not in stock:
            raise ValueError('Missing stock secure library: ' + name)
        if name not in STOCK_LIBRARY_SHA256 or sha256(stock[path]) != STOCK_LIBRARY_SHA256[name]:
            raise ValueError('Unsupported stock secure library fingerprint: ' + name)
        selected[name] = elf_metadata(stock[path])
        pending.extend(selected[name]['needed'])
    exports = set(metadata['exports'])
    for library in selected.values():
        exports.update(library['exports'])
    missing = sorted(metadata['strong_imports'] - exports)
    if missing:
        raise ValueError('Unresolved FKeyMaster imports: ' + ', '.join(missing))
    providers = {name: versioned_symbols(stock['/lib64/' + name])[1] for name in selected}
    for symbol, binding in versioned_symbols(ta_payload(container))[0]:
        if binding:
            provider, version = binding
            if (symbol, version) not in providers.get(provider, set()):
                raise ValueError(f'Unresolved versioned FKeyMaster import: {symbol}@{version} from {provider}')
    return sorted(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stock-tzar', type=Path, required=True)
    args = parser.parse_args()
    original = args.input.read_bytes()
    result = adapt(original)
    libraries = verify_stock_bindings(result, args.stock_tzar)
    write_file(args.output, result)
    print(f'Prepared stock-ABI FKeyMaster ({len(result)} bytes); {len(libraries)} existing secure libraries, no added TZAR records')


if __name__ == '__main__':
    main()
