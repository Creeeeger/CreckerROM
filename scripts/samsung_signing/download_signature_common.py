# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import hashlib
import shutil
import struct
from dataclasses import dataclass
from pathlib import Path

from stage2_common import (
    DEFAULT_KEY_INDEX,
    SIGN_TYPE_ECDSA_NIST_P384,
    STAGE2_FOOTER_HEADER_SIZE,
    STAGE2_SIGNATURE_SIZE,
    read_u32,
    write_u32,
)

SPARSE_MAGIC = 0xED26FF3A
SPARSE_RAW_CHUNK = 0xCAC1
DOWNLOAD_SIGNATURE_RECORD_SIZE = 0x300
SIGNER_INFO_SIZE = 0x100
STREAM_CHUNK_SIZE = 8 * 1024 * 1024


@dataclass
class DownloadSignatureLayout:
    file_size: int
    file_header_size: int
    chunk_header_size: int
    signature_record_offset: int
    signer_info_offset: int
    signer_version: int
    rp_count: int
    sign_type: int
    key_type: int
    key_index: int

    @property
    def signature_offset(self):
        return self.signature_record_offset + STAGE2_FOOTER_HEADER_SIZE

    @property
    def payload_offset(self):
        return self.signer_info_offset


def _read_prefix(path, size):
    with Path(path).open("rb") as f:
        return f.read(size)


def _signer_version(prefix, offset):
    marker = prefix[offset:offset + 11]
    if marker.lower() == b"signerver01":
        return 1
    if marker.lower() == b"signerver02":
        return 2
    if marker.lower() == b"signerver03":
        return 3
    return 0


def parse_download_signature_layout(path):
    path = Path(path)
    file_size = path.stat().st_size
    prefix = _read_prefix(path, 0x20)
    if len(prefix) < 0x0C:
        raise ValueError("Image is too small for a sparse download signature")
    if read_u32(prefix, 0) != SPARSE_MAGIC:
        raise ValueError("Only Android sparse images are supported by this signer")

    file_header_size = struct.unpack_from("<H", prefix, 8)[0]
    chunk_header_size = struct.unpack_from("<H", prefix, 10)[0]
    if file_header_size < 0x1C or chunk_header_size < 0x0C:
        raise ValueError("Sparse file/chunk header sizes are invalid")

    needed_prefix = file_header_size + chunk_header_size + DOWNLOAD_SIGNATURE_RECORD_SIZE + SIGNER_INFO_SIZE
    prefix = _read_prefix(path, needed_prefix)
    if len(prefix) < needed_prefix:
        raise ValueError("Image prefix is too small for the sparse download signature record")

    chunk_type = struct.unpack_from("<H", prefix, file_header_size)[0]
    if chunk_type != SPARSE_RAW_CHUNK:
        raise ValueError("First sparse chunk is not a raw chunk; download signature layout is unsupported")

    signature_record_offset = file_header_size + chunk_header_size
    signer_info_offset = signature_record_offset + DOWNLOAD_SIGNATURE_RECORD_SIZE
    signer_version = _signer_version(prefix, signer_info_offset)
    if signer_version == 0:
        raise ValueError("No SignerVer metadata found after the sparse download signature record")
    if signer_version != 3:
        raise ValueError(f"Only SignerVer03 sparse download signatures are implemented, got SignerVer0{signer_version}")

    return DownloadSignatureLayout(
        file_size=file_size,
        file_header_size=file_header_size,
        chunk_header_size=chunk_header_size,
        signature_record_offset=signature_record_offset,
        signer_info_offset=signer_info_offset,
        signer_version=signer_version,
        rp_count=read_u32(prefix, signature_record_offset),
        sign_type=read_u32(prefix, signature_record_offset + 4),
        key_type=read_u32(prefix, signature_record_offset + 8),
        key_index=read_u32(prefix, signature_record_offset + 12),
    )


def download_signature_header(rp_count, sign_type, key_type, key_index):
    return b"".join((
        write_u32(rp_count),
        write_u32(sign_type),
        write_u32(key_type),
        write_u32(key_index),
    ))


def select_download_header_values(layout, rp_count, sign_type, key_type_arg, key_index_arg):
    key_type = layout.key_type if key_type_arg is None else key_type_arg
    key_index = layout.key_index if key_index_arg is None and layout.key_index != 0 else key_index_arg
    if key_index is None:
        key_index = DEFAULT_KEY_INDEX
    return rp_count, sign_type, key_type, key_index


def hash_file_range(path, start_offset):
    digest = hashlib.sha512()
    with Path(path).open("rb") as f:
        f.seek(start_offset)
        while True:
            chunk = f.read(STREAM_CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.digest()


def download_final_digest(path, layout, header):
    if len(header) != STAGE2_FOOTER_HEADER_SIZE:
        raise ValueError("Download signature header must be 0x10 bytes")
    payload_digest = hash_file_range(path, layout.payload_offset)
    return payload_digest, hashlib.sha512(payload_digest + header).digest()


def read_download_signature_blob(path, layout):
    with Path(path).open("rb") as f:
        f.seek(layout.signature_offset)
        blob = f.read(STAGE2_SIGNATURE_SIZE)
    if len(blob) != STAGE2_SIGNATURE_SIZE:
        raise ValueError("Could not read the full sparse download signature blob")
    return blob


def copy_with_download_signature(input_path, output_path, layout, header, signature_blob):
    input_path = Path(input_path)
    output_path = Path(output_path)
    if input_path.resolve() == output_path.resolve():
        raise ValueError("Input and output paths must be different")
    if len(signature_blob) != STAGE2_SIGNATURE_SIZE:
        raise ValueError("Signature blob must be 0x200 bytes")

    with input_path.open("rb") as src, output_path.open("wb") as dst:
        shutil.copyfileobj(src, dst, length=STREAM_CHUNK_SIZE)

    with output_path.open("r+b") as f:
        f.seek(layout.signature_record_offset)
        f.write(header)
        f.seek(layout.signature_offset)
        f.write(signature_blob)
