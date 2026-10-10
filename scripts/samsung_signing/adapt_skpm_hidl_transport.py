#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
"""Route the pinned donor SKPM transport through the existing stock HIDL client."""

import argparse
from pathlib import Path

from teegris_elf import elf_metadata, sha256, write_file
from parse_tas import parse_elf

SOURCE_SHA256 = '40bea2d1d1cf88e3d12ac1c31c3340840f97fa79b31309aaba2315047a087423'
CLIENT_SHA256 = 'cdb47a48c2d3feac29481f4bb119ddc07f3c6170e4fa1a639ade2c33f69424ba'
INTERFACE_SHA256 = '3f61d23ab219a8b450d373f79d3d76f28cc69bbfc2c9c06f323eef199cce576b'
OLD_DEPENDENCY = 'libsec_skpmAidl.so'
NEW_DEPENDENCY = 'libsec_skpmHal.so'
C_ABI = {'skpm_hidl_loadTa', 'skpm_hidl_invokeCmd', 'skpm_hidl_unloadTa'}


def adapt(data, client, interface):
    for label, content, expected in [('donor transport', data, SOURCE_SHA256),
                                     ('stock HIDL client', client, CLIENT_SHA256),
                                     ('stock HIDL interface', interface, INTERFACE_SHA256)]:
        if sha256(content) != expected:
            raise ValueError('Unsupported SKPM ' + label + ' fingerprint')
    original = elf_metadata(data)
    stock = elf_metadata(client)
    if {n for n in original['strong_imports'] if n.startswith('skpm_hidl_')} != C_ABI:
        raise ValueError('Unexpected SKPM C transport API')
    if not C_ABI <= stock['exports']:
        raise ValueError('Stock SKPM client lacks the required C transport API')
    if 'vendor.samsung.hardware.security.skpm@1.0.so' not in stock['needed']:
        raise ValueError('Stock SKPM client does not use the HIDL interface')
    if elf_metadata(interface)['soname'] != 'vendor.samsung.hardware.security.skpm@1.0.so':
        raise ValueError('Unexpected SKPM HIDL interface SONAME')
    if original['needed'].count(OLD_DEPENDENCY) != 1:
        raise ValueError('Missing donor SKPM AIDL dependency')
    strings = parse_elf(data, 0)['sections']['.dynstr']
    old, new = OLD_DEPENDENCY.encode() + b'\0', NEW_DEPENDENCY.encode() + b'\0'
    pool = data[strings['offset']:strings['offset'] + strings['size']]
    if pool.count(old) != 1 or len(new) > len(old):
        raise ValueError('Unexpected SKPM dependency string layout')
    offset = strings['offset'] + pool.index(old)
    result = data[:offset] + new.ljust(len(old), b'\0') + data[offset + len(old):]
    metadata = elf_metadata(result)
    if metadata['needed'] != [NEW_DEPENDENCY if n == OLD_DEPENDENCY else n for n in original['needed']]:
        raise ValueError('SKPM dependency rewrite failed')
    for field in ('soname', 'strong_imports', 'exports', 'versions', 'interpreter'):
        if metadata[field] != original[field]:
            raise ValueError('Unexpected SKPM ELF change: ' + field)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stock-client', type=Path, required=True)
    parser.add_argument('--stock-interface', type=Path, required=True)
    args = parser.parse_args()
    source = args.input.read_bytes()
    result = adapt(source, args.stock_client.read_bytes(), args.stock_interface.read_bytes())
    write_file(args.output, result)
    print('SKPM transport uses the existing stock HIDL service; secure-world images unchanged')


if __name__ == '__main__':
    main()
