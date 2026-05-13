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
SPARSE_FILL_CHUNK = 0xCAC2
SPARSE_DONT_CARE_CHUNK = 0xCAC3
SPARSE_CRC32_CHUNK = 0xCAC4
DOWNLOAD_SIGNATURE_RECORD_SIZE = 0x300
SIGNER_INFO_SIZE = 0x100
STREAM_CHUNK_SIZE = 8 * 1024 * 1024

LP_PARTITION_RESERVED_BYTES = 4096
LP_METADATA_GEOMETRY_SIZE = 4096
LP_METADATA_GEOMETRY_MAGIC = 0x616C4467
LP_METADATA_HEADER_MAGIC = 0x414C5030
LP_SECTOR_SIZE = 512
LP_METADATA_GEOMETRY_STRUCT_SIZE = 52
LP_METADATA_HEADER_MIN_SIZE = 128
LP_METADATA_BLOCK_DEVICE_MIN_SIZE = 64

DEFAULT_SUPER_REFERENCE = "super_signed.img"


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


@dataclass
class SparseHeader:
    file_size: int
    header_bytes: bytes
    file_header_size: int
    chunk_header_size: int
    block_size: int
    total_blocks: int
    total_chunks: int
    image_checksum: int

    @property
    def output_size(self):
        return self.block_size * self.total_blocks


@dataclass
class SparseChunk:
    index: int
    header_offset: int
    data_offset: int
    output_offset: int
    chunk_type: int
    reserved: int
    chunk_blocks: int
    total_size: int
    data_size: int

    @property
    def output_blocks(self):
        return self.chunk_blocks


@dataclass
class SuperSigningDefaults:
    rp_count: int
    sign_type: int
    key_type: int
    key_index: int
    signer_info: bytes


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


def signer_info_version(signer_info):
    return _signer_version(signer_info, 0)


def signer_info_string(signer_info, offset, size):
    return signer_info[offset:offset + size].split(b"\x00", 1)[0].decode("ascii", "replace")


def signer_info_quick_build_id(signer_info):
    return signer_info_string(signer_info, 16, 16)


def signer_info_binary_name(signer_info):
    return signer_info_string(signer_info, 156, 16)


def read_sparse_header(path):
    path = Path(path)
    file_size = path.stat().st_size
    prefix = _read_prefix(path, 0x1C)
    if len(prefix) < 0x1C:
        raise ValueError("Image is too small for an Android sparse header")

    magic, major, _minor, file_header_size, chunk_header_size, block_size, total_blocks, total_chunks, checksum = (
        struct.unpack_from("<IHHHHIIII", prefix, 0)
    )
    if magic != SPARSE_MAGIC:
        raise ValueError("Only Android sparse images are supported by this signer")
    if major != 1:
        raise ValueError(f"Unsupported Android sparse major version: {major}")
    if file_header_size < 0x1C or chunk_header_size < 0x0C:
        raise ValueError("Sparse file/chunk header sizes are invalid")
    if block_size < DOWNLOAD_SIGNATURE_RECORD_SIZE + SIGNER_INFO_SIZE:
        raise ValueError("Sparse block size is too small for the Samsung signer block")
    if block_size % 4 != 0:
        raise ValueError("Sparse block size must be divisible by 4")

    header_bytes = _read_prefix(path, file_header_size)
    if len(header_bytes) != file_header_size:
        raise ValueError("Could not read the full sparse header")

    return SparseHeader(
        file_size=file_size,
        header_bytes=header_bytes,
        file_header_size=file_header_size,
        chunk_header_size=chunk_header_size,
        block_size=block_size,
        total_blocks=total_blocks,
        total_chunks=total_chunks,
        image_checksum=checksum,
    )


def _chunk_data_size(header, chunk_type, chunk_blocks, total_size):
    if total_size < header.chunk_header_size:
        raise ValueError("Sparse chunk total size is smaller than the chunk header")

    data_size = total_size - header.chunk_header_size
    if chunk_type == SPARSE_RAW_CHUNK:
        expected = chunk_blocks * header.block_size
    elif chunk_type == SPARSE_FILL_CHUNK:
        expected = 4
    elif chunk_type == SPARSE_DONT_CARE_CHUNK:
        expected = 0
    elif chunk_type == SPARSE_CRC32_CHUNK:
        expected = 4
    else:
        raise ValueError(f"Unsupported sparse chunk type: 0x{chunk_type:X}")

    if data_size != expected:
        raise ValueError(
            f"Sparse chunk size mismatch for type 0x{chunk_type:X}: got 0x{data_size:X}, expected 0x{expected:X}"
        )
    return data_size


def iter_sparse_chunks(path, header=None):
    path = Path(path)
    header = header if header is not None else read_sparse_header(path)
    output_offset = 0
    with path.open("rb") as f:
        f.seek(header.file_header_size)
        for index in range(header.total_chunks):
            header_offset = f.tell()
            chunk_header = f.read(header.chunk_header_size)
            if len(chunk_header) != header.chunk_header_size:
                raise ValueError(f"Could not read sparse chunk header {index}")
            chunk_type, reserved, chunk_blocks, total_size = struct.unpack_from("<HHII", chunk_header, 0)
            data_size = _chunk_data_size(header, chunk_type, chunk_blocks, total_size)
            data_offset = f.tell()
            yield SparseChunk(
                index=index,
                header_offset=header_offset,
                data_offset=data_offset,
                output_offset=output_offset,
                chunk_type=chunk_type,
                reserved=reserved,
                chunk_blocks=chunk_blocks,
                total_size=total_size,
                data_size=data_size,
            )
            f.seek(data_size, 1)
            output_offset += chunk_blocks * header.block_size

    if output_offset != header.output_size:
        raise ValueError(
            f"Sparse chunks produce 0x{output_offset:X} bytes, header declares 0x{header.output_size:X}"
        )


def first_sparse_chunk(path, header=None):
    for chunk in iter_sparse_chunks(path, header):
        return chunk
    raise ValueError("Sparse image does not contain any chunks")


def sparse_chunk_header(header, chunk_type, reserved, chunk_blocks, total_size):
    raw = bytearray(header.chunk_header_size)
    struct.pack_into("<HHII", raw, 0, chunk_type, reserved, chunk_blocks, total_size)
    return bytes(raw)


def sparse_file_header(header, total_chunks=None, image_checksum=0):
    raw = bytearray(header.header_bytes)
    if total_chunks is None:
        total_chunks = header.total_chunks
    struct.pack_into("<I", raw, 20, total_chunks)
    struct.pack_into("<I", raw, 24, image_checksum)
    return bytes(raw)


def read_sparse_range(path, start_offset, size, header=None):
    if size < 0:
        raise ValueError("Sparse range size must not be negative")
    if size == 0:
        return b""

    path = Path(path)
    header = header if header is not None else read_sparse_header(path)
    end_offset = start_offset + size
    if start_offset < 0 or end_offset > header.output_size:
        raise ValueError("Requested sparse output range is outside the image")

    out = bytearray()
    with path.open("rb") as f:
        for chunk in iter_sparse_chunks(path, header):
            chunk_start = chunk.output_offset
            chunk_end = chunk_start + chunk.chunk_blocks * header.block_size
            overlap_start = max(start_offset, chunk_start)
            overlap_end = min(end_offset, chunk_end)
            if overlap_start >= overlap_end:
                continue

            rel = overlap_start - chunk_start
            need = overlap_end - overlap_start
            if chunk.chunk_type == SPARSE_RAW_CHUNK:
                f.seek(chunk.data_offset + rel)
                data = f.read(need)
                if len(data) != need:
                    raise ValueError("Could not read requested sparse raw range")
                out.extend(data)
            elif chunk.chunk_type == SPARSE_FILL_CHUNK:
                f.seek(chunk.data_offset)
                fill = f.read(4)
                if len(fill) != 4:
                    raise ValueError("Could not read sparse fill value")
                repeated = fill * ((rel % 4 + need + 3) // 4 + 1)
                out.extend(repeated[rel % 4:rel % 4 + need])
            elif chunk.chunk_type == SPARSE_DONT_CARE_CHUNK:
                out.extend(b"\x00" * need)
            else:
                raise ValueError("Cannot read data from sparse CRC32 chunk")

            if len(out) == size:
                break

    if len(out) != size:
        raise ValueError("Could not read the requested sparse output range")
    return bytes(out)


def parse_download_signature_layout(path):
    header = read_sparse_header(path)
    chunk = first_sparse_chunk(path, header)
    if chunk.output_offset != 0 or chunk.chunk_type != SPARSE_RAW_CHUNK or chunk.chunk_blocks < 1:
        raise ValueError("First sparse output block is not a raw Samsung signer block")

    needed_prefix = chunk.data_offset + DOWNLOAD_SIGNATURE_RECORD_SIZE + SIGNER_INFO_SIZE
    prefix = _read_prefix(path, needed_prefix)
    if len(prefix) < needed_prefix:
        raise ValueError("Image prefix is too small for the sparse download signature record")

    signature_record_offset = chunk.data_offset
    signer_info_offset = signature_record_offset + DOWNLOAD_SIGNATURE_RECORD_SIZE
    signer_version = _signer_version(prefix, signer_info_offset)
    if signer_version == 0:
        raise ValueError("No SignerVer metadata found after the sparse download signature record")
    if signer_version != 3:
        raise ValueError(f"Only SignerVer03 sparse download signatures are implemented, got SignerVer0{signer_version}")

    return DownloadSignatureLayout(
        file_size=header.file_size,
        file_header_size=header.file_header_size,
        chunk_header_size=header.chunk_header_size,
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


def read_download_signer_info(path, layout):
    with Path(path).open("rb") as f:
        f.seek(layout.signer_info_offset)
        signer_info = f.read(SIGNER_INFO_SIZE)
    if len(signer_info) != SIGNER_INFO_SIZE:
        raise ValueError("Could not read the full SignerInfo block")
    if signer_info_version(signer_info) == 0:
        raise ValueError("SignerInfo block does not contain a SignerVer marker")
    return signer_info


def load_super_signing_defaults(path):
    layout = parse_download_signature_layout(path)
    return SuperSigningDefaults(
        rp_count=layout.rp_count,
        sign_type=layout.sign_type,
        key_type=layout.key_type,
        key_index=layout.key_index,
        signer_info=read_download_signer_info(path, layout),
    )


def sparse_image_has_super_metadata(path):
    try:
        read_super_first_logical_sector(path)
        return True
    except ValueError:
        return False


def read_super_first_logical_sector(path):
    header = read_sparse_header(path)
    geometry = read_sparse_range(path, LP_PARTITION_RESERVED_BYTES, LP_METADATA_GEOMETRY_SIZE, header)
    if read_u32(geometry, 0) != LP_METADATA_GEOMETRY_MAGIC:
        raise ValueError("Sparse image does not contain Android super geometry metadata")
    if read_u32(geometry, 4) != LP_METADATA_GEOMETRY_STRUCT_SIZE:
        raise ValueError("Unsupported Android super geometry struct size")

    metadata_max_size = read_u32(geometry, 40)
    metadata_slot_count = read_u32(geometry, 44)
    if metadata_max_size == 0 or metadata_max_size % LP_SECTOR_SIZE != 0:
        raise ValueError("Android super metadata max size is invalid")
    if metadata_slot_count == 0:
        raise ValueError("Android super metadata slot count is invalid")

    metadata_base = LP_PARTITION_RESERVED_BYTES + (LP_METADATA_GEOMETRY_SIZE * 2)
    for slot_number in range(metadata_slot_count):
        metadata_offset = metadata_base + metadata_max_size * slot_number
        try:
            metadata_header = read_sparse_range(path, metadata_offset, LP_METADATA_HEADER_MIN_SIZE, header)
        except ValueError:
            continue
        if read_u32(metadata_header, 0) != LP_METADATA_HEADER_MAGIC:
            continue

        header_size = read_u32(metadata_header, 8)
        tables_size = read_u32(metadata_header, 44)
        if header_size < LP_METADATA_HEADER_MIN_SIZE:
            raise ValueError("Android super metadata header size is invalid")
        if tables_size == 0:
            raise ValueError("Android super metadata tables are empty")

        block_devices_offset, block_devices_count, block_devices_entry_size = struct.unpack_from(
            "<III", metadata_header, 116
        )
        if block_devices_count < 1:
            raise ValueError("Android super metadata has no block device table")
        if block_devices_entry_size < LP_METADATA_BLOCK_DEVICE_MIN_SIZE:
            raise ValueError("Android super block device entry size is invalid")
        if block_devices_offset + block_devices_entry_size > tables_size:
            raise ValueError("Android super block device table is outside metadata tables")

        block_device = read_sparse_range(
            path,
            metadata_offset + header_size + block_devices_offset,
            block_devices_entry_size,
            header,
        )
        first_logical_sector = struct.unpack_from("<Q", block_device, 0)[0]
        if first_logical_sector == 0:
            raise ValueError("Android super first logical sector is invalid")
        return first_logical_sector

    raise ValueError("Could not find a valid Android super metadata header")


def super_signer_info_output_offset(path):
    return read_super_first_logical_sector(path) * LP_SECTOR_SIZE + DOWNLOAD_SIGNATURE_RECORD_SIZE


def read_super_embedded_signer_info(path):
    signer_info = read_sparse_range(path, super_signer_info_output_offset(path), SIGNER_INFO_SIZE)
    if signer_info_version(signer_info) == 0:
        raise ValueError("No embedded SignerInfo block found in Android super data area")
    return signer_info


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


def write_download_signature(path, layout, header, signature_blob):
    path = Path(path)
    if len(header) != STAGE2_FOOTER_HEADER_SIZE:
        raise ValueError("Download signature header must be 0x10 bytes")
    if len(signature_blob) != STAGE2_SIGNATURE_SIZE:
        raise ValueError("Signature blob must be 0x200 bytes")

    with path.open("r+b") as f:
        f.seek(layout.signature_record_offset)
        f.write(header)
        f.seek(layout.signature_offset)
        f.write(signature_blob)


def copy_with_download_signature(input_path, output_path, layout, header, signature_blob):
    input_path = Path(input_path)
    output_path = Path(output_path)
    if input_path.resolve() == output_path.resolve():
        raise ValueError("Input and output paths must be different")

    with input_path.open("rb") as src, output_path.open("wb") as dst:
        shutil.copyfileobj(src, dst, length=STREAM_CHUNK_SIZE)

    write_download_signature(output_path, layout, header, signature_blob)


def build_super_first_block(header, signer_info):
    if len(header) != STAGE2_FOOTER_HEADER_SIZE:
        raise ValueError("Download signature header must be 0x10 bytes")
    if len(signer_info) != SIGNER_INFO_SIZE:
        raise ValueError("SignerInfo block must be 0x100 bytes")
    if signer_info_version(signer_info) != 3:
        raise ValueError("Only SignerVer03 super SignerInfo blocks are implemented")

    block = bytearray(DOWNLOAD_SIGNATURE_RECORD_SIZE + SIGNER_INFO_SIZE)
    block[:len(header)] = header
    block[DOWNLOAD_SIGNATURE_RECORD_SIZE:DOWNLOAD_SIGNATURE_RECORD_SIZE + SIGNER_INFO_SIZE] = signer_info
    return bytes(block)


def first_block_can_be_replaced(path, sparse_header):
    first_block = read_sparse_range(path, 0, sparse_header.block_size, sparse_header)
    signer_info = first_block[DOWNLOAD_SIGNATURE_RECORD_SIZE:DOWNLOAD_SIGNATURE_RECORD_SIZE + SIGNER_INFO_SIZE]
    if signer_info_version(signer_info) != 0:
        return True
    return first_block == b"\x00" * sparse_header.block_size


def raw_chunk_contains_range(chunk, sparse_header, start_offset, size):
    if chunk.chunk_type != SPARSE_RAW_CHUNK:
        return False
    chunk_start = chunk.output_offset
    chunk_end = chunk_start + chunk.chunk_blocks * sparse_header.block_size
    return chunk_start <= start_offset and start_offset + size <= chunk_end


def find_raw_sparse_chunk_for_range(path, sparse_header, start_offset, size):
    for chunk in iter_sparse_chunks(path, sparse_header):
        if raw_chunk_contains_range(chunk, sparse_header, start_offset, size):
            return chunk
    return None


def _copy_exact(src, dst, size):
    remaining = size
    while remaining:
        chunk = src.read(min(STREAM_CHUNK_SIZE, remaining))
        if not chunk:
            raise ValueError("Unexpected EOF while copying sparse data")
        dst.write(chunk)
        remaining -= len(chunk)


def _skip_exact(src, size):
    if size:
        src.seek(size, 1)


def _copy_raw_chunk_data_with_patch(src, dst, chunk, sparse_header, patch_offset, patch_data):
    patch_end = patch_offset + len(patch_data)
    chunk_start = chunk.output_offset
    chunk_end = chunk_start + chunk.chunk_blocks * sparse_header.block_size
    overlap_start = max(chunk_start, patch_offset)
    overlap_end = min(chunk_end, patch_end)

    if overlap_start >= overlap_end:
        _copy_exact(src, dst, chunk.data_size)
        return

    before = overlap_start - chunk_start
    _copy_exact(src, dst, before)

    patch_start = overlap_start - patch_offset
    patch_size = overlap_end - overlap_start
    _skip_exact(src, patch_size)
    dst.write(patch_data[patch_start:patch_start + patch_size])

    after = chunk.data_size - before - patch_size
    _copy_exact(src, dst, after)


def copy_with_super_signature(input_path, output_path, header, signer_info):
    input_path = Path(input_path)
    output_path = Path(output_path)
    if input_path.resolve() == output_path.resolve():
        raise ValueError("Input and output paths must be different")

    sparse_header = read_sparse_header(input_path)
    first_chunk = first_sparse_chunk(input_path, sparse_header)
    if first_chunk.output_offset != 0 or first_chunk.chunk_blocks < 1:
        raise ValueError("First sparse chunk does not cover output block 0")
    if first_chunk.chunk_type == SPARSE_CRC32_CHUNK:
        raise ValueError("First sparse chunk cannot be a CRC32 chunk")
    if not first_block_can_be_replaced(input_path, sparse_header):
        raise ValueError("First sparse output block is not empty or already signed")

    embedded_signer_offset = super_signer_info_output_offset(input_path)
    if embedded_signer_offset + SIGNER_INFO_SIZE > sparse_header.output_size:
        raise ValueError("Embedded super SignerInfo offset is outside the sparse output image")
    if find_raw_sparse_chunk_for_range(input_path, sparse_header, embedded_signer_offset, SIGNER_INFO_SIZE) is None:
        raise ValueError("Embedded super SignerInfo location is not inside a raw sparse chunk")

    first_block = bytearray(sparse_header.block_size)
    signer_prefix = build_super_first_block(header, signer_info)
    first_block[:len(signer_prefix)] = signer_prefix

    chunk_delta = 0
    if first_chunk.chunk_type in (SPARSE_RAW_CHUNK, SPARSE_FILL_CHUNK, SPARSE_DONT_CARE_CHUNK) and first_chunk.chunk_blocks > 1:
        chunk_delta = 1

    with input_path.open("rb") as src, output_path.open("wb") as dst:
        src.seek(sparse_header.file_header_size)
        dst.write(sparse_file_header(sparse_header, sparse_header.total_chunks + chunk_delta, image_checksum=0))

        output_offset = 0
        for index in range(sparse_header.total_chunks):
            chunk_header = src.read(sparse_header.chunk_header_size)
            if len(chunk_header) != sparse_header.chunk_header_size:
                raise ValueError(f"Could not read sparse chunk header {index}")
            chunk_type, reserved, chunk_blocks, total_size = struct.unpack_from("<HHII", chunk_header, 0)
            data_size = _chunk_data_size(sparse_header, chunk_type, chunk_blocks, total_size)
            chunk = SparseChunk(
                index=index,
                header_offset=src.tell() - sparse_header.chunk_header_size,
                data_offset=src.tell(),
                output_offset=output_offset,
                chunk_type=chunk_type,
                reserved=reserved,
                chunk_blocks=chunk_blocks,
                total_size=total_size,
                data_size=data_size,
            )

            if index == 0:
                raw_total = sparse_header.chunk_header_size + sparse_header.block_size
                dst.write(sparse_chunk_header(sparse_header, SPARSE_RAW_CHUNK, 0, 1, raw_total))
                dst.write(first_block)

                if chunk_type == SPARSE_RAW_CHUNK:
                    if chunk_blocks > 1:
                        remaining_blocks = chunk_blocks - 1
                        remaining_total = sparse_header.chunk_header_size + remaining_blocks * sparse_header.block_size
                        dst.write(sparse_chunk_header(
                            sparse_header,
                            SPARSE_RAW_CHUNK,
                            reserved,
                            remaining_blocks,
                            remaining_total,
                        ))
                        _skip_exact(src, sparse_header.block_size)
                        _copy_raw_chunk_data_with_patch(
                            src,
                            dst,
                            SparseChunk(
                                index=index,
                                header_offset=chunk.header_offset,
                                data_offset=chunk.data_offset + sparse_header.block_size,
                                output_offset=output_offset + sparse_header.block_size,
                                chunk_type=SPARSE_RAW_CHUNK,
                                reserved=reserved,
                                chunk_blocks=remaining_blocks,
                                total_size=remaining_total,
                                data_size=data_size - sparse_header.block_size,
                            ),
                            sparse_header,
                            embedded_signer_offset,
                            signer_info,
                        )
                    else:
                        _skip_exact(src, data_size)
                elif chunk_type == SPARSE_FILL_CHUNK:
                    fill = src.read(4)
                    if len(fill) != 4:
                        raise ValueError("Could not read sparse fill value")
                    if fill != b"\x00" * 4:
                        raise ValueError("First sparse fill block is not zero-filled")
                    if chunk_blocks > 1:
                        dst.write(sparse_chunk_header(
                            sparse_header,
                            SPARSE_FILL_CHUNK,
                            reserved,
                            chunk_blocks - 1,
                            sparse_header.chunk_header_size + 4,
                        ))
                        dst.write(fill)
                elif chunk_type == SPARSE_DONT_CARE_CHUNK:
                    if chunk_blocks > 1:
                        dst.write(sparse_chunk_header(
                            sparse_header,
                            SPARSE_DONT_CARE_CHUNK,
                            reserved,
                            chunk_blocks - 1,
                            sparse_header.chunk_header_size,
                        ))
                else:
                    raise ValueError(f"Unsupported first sparse chunk type: 0x{chunk_type:X}")
            else:
                dst.write(chunk_header)
                if chunk_type == SPARSE_RAW_CHUNK:
                    _copy_raw_chunk_data_with_patch(src, dst, chunk, sparse_header, embedded_signer_offset, signer_info)
                else:
                    _copy_exact(src, dst, data_size)

            output_offset += chunk_blocks * sparse_header.block_size

    return parse_download_signature_layout(output_path), embedded_signer_offset
