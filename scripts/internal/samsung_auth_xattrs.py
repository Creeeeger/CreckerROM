#!/usr/bin/env python3
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later
"""Keep Samsung S OS PROCA certificates only while their file binding matches.

Certificate signatures remain the responsibility of PROCA and the TEE. This
checks the file binding used by is_certificate_relevant_to_file(): SHA256 of
the file's SHA1 digest. It never creates or re-signs authentication metadata.
"""

import argparse
import errno
import hashlib
import os
from pathlib import Path


def read_der(data, offset, tag):
    if offset + 2 > len(data) or data[offset] != tag:
        raise ValueError("unexpected certificate field")
    size = data[offset + 1]
    offset += 2
    if size & 0x80:
        count = size & 0x7f
        if not 0 < count <= 4 or offset + count > len(data):
            raise ValueError("invalid certificate length")
        size = int.from_bytes(data[offset:offset + count], "big")
        offset += count
    end = offset + size
    if end > len(data):
        raise ValueError("truncated certificate")
    return data[offset:end], end


def certificate_file_hash(certificate):
    # PaCertificate and PaData, as declared by proca_certificate.asn1.
    sequence, end = read_der(certificate, 0, 0x30)
    if end != len(certificate):
        raise ValueError("trailing certificate data")
    fields, end = read_der(sequence, 0, 0x30)
    signature, end = read_der(sequence, end, 0x04)
    if end != len(sequence) or not signature:
        raise ValueError("invalid certificate signature field")
    offset = 0
    for tag in (0x02, 0x02, 0x02, 0x04, 0x04):
        value, offset = read_der(fields, offset, tag)
        if not value:
            raise ValueError("empty certificate field")
    digest, end = read_der(fields, offset, 0x04)
    if end != len(fields) or len(digest) != hashlib.sha256().digest_size:
        raise ValueError("invalid certificate file hash")
    return digest


def file_hash(path):
    # SHA1 is part of Samsung's existing certificate format.
    digest = hashlib.sha1(usedforsecurity=False)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return hashlib.sha256(digest.digest()).digest()


def prepare_certificates(root, check_only=False):
    kept = removed = 0

    def walk_error(error):
        raise error

    for directory, _, files in os.walk(root, followlinks=False, onerror=walk_error):
        for name in files:
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            try:
                certificate = os.getxattr(path, "user.pa", follow_symlinks=False)
            except OSError as error:
                if error.errno == errno.ENODATA:
                    continue
                raise
            try:
                matches = certificate_file_hash(certificate) == file_hash(path)
            except ValueError:
                matches = False
            if matches:
                kept += 1
                continue
            if not check_only:
                os.removexattr(path, "user.pa", follow_symlinks=False)
            print(f"PROCA: {'stale' if check_only else 'removed stale'} user.pa: {path}")
            removed += 1
    print(f"PROCA: preserved {kept} matching certificates; "
          f"{'found' if check_only else 'removed'} {removed} stale certificates")
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error(f"partition directory does not exist: {args.root}")
    try:
        stale = prepare_certificates(args.root, args.check_only)
    except OSError as error:
        parser.exit(1, f"PROCA metadata check failed: {error}\n")
    return int(args.check_only and stale > 0)


if __name__ == "__main__":
    raise SystemExit(main())
