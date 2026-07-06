#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import struct
from dataclasses import dataclass
from pathlib import Path

SPARSE_MAGIC = 0xED26FF3A
SPARSE_RAW_CHUNK = 0xCAC1
SPARSE_FILL_CHUNK = 0xCAC2
SPARSE_DONT_CARE_CHUNK = 0xCAC3
SPARSE_CRC32_CHUNK = 0xCAC4
DOWNLOAD_SIGNATURE_RECORD_SIZE = 0x300
SIGNER_INFO_SIZE = 0x100
STREAM_CHUNK_SIZE = 8 * 1024 * 1024


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



def _read_prefix(path, size):
    with Path(path).open("rb") as f:
        return f.read(size)

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

    # Return logical output bytes from the sparse image without materializing the
    # complete unsparsed file.
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
