#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import hashlib
import json
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

import lz4.block
import lz4.frame
from stage2_common import looks_like_stage2_footer, parse_stage2_footer

OUTER_LZ4_MAGIC = b"\x04\x22\x4d\x18"
LEGACY_LZ4_MAGIC = b"\x02\x21\x4c\x18"
TZAR_MAGIC = b"\x7f\xa5TA"
TZAR_HEADER_SIZE = 0x10
MANIFEST_NAME = "tzar_manifest.json"
FILES_DIR = "files"
RAW_DIR = "_raw"

def sha256(data):
    return hashlib.sha256(data).hexdigest()


def startup_object_hash(record):
    # userboot verifies each startup.tzar object as SHA256(path || payload).
    return hashlib.sha256(record["path"].encode("utf-8") + record["payload"]).digest()


def startup_object_hash_hex(record):
    return startup_object_hash(record).hex()


def startup_hash_table(records):
    return b"".join(startup_object_hash(record) for record in sorted(records, key=lambda item: item["index"]))


def find_userboot_hash_table(data, record_count):
    marker = b"ub_tzar_walk_cb\x00"
    marker_offset = data.find(marker)
    if marker_offset < 0:
        raise ValueError(
            "Could not find the userboot TZAR hash marker in tzsw.img. "
            "Use a decrypted/clear tzsw.img as TARGET_SAMSUNG_DECRYPTED_TZSW_PATH."
        )

    table_offset = marker_offset + len(marker)
    table_size = record_count * hashlib.sha256().digest_size
    if table_offset + table_size > len(data):
        raise ValueError(
            f"Userboot TZAR hash table extends past tzsw.img: "
            f"off=0x{table_offset:X} size=0x{table_size:X} image=0x{len(data):X}"
        )
    return table_offset, table_size


def repo_root():
    path = Path(__file__).resolve()
    if len(path.parents) >= 3 and path.parents[1].name == "external":
        return path.parents[2]
    return Path.cwd()


def default_keys_dir():
    candidate = repo_root() / "external" / "keys" / "exynos9830_crecker"
    if candidate.is_dir():
        return candidate
    return Path.cwd()


def require_lz4():
    if shutil.which("lz4") is None:
        raise RuntimeError("lz4 executable was not found in PATH")


def run_lz4(args, check=True):
    require_lz4()
    proc = subprocess.run(["lz4", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", "replace").strip())
    return proc


def lz4_decompress(data, allow_trailing=False, expected_size=None):
    if data.startswith(OUTER_LZ4_MAGIC):
        output = lz4.frame.decompress(data)
        if expected_size is not None and len(output) != expected_size:
            raise ValueError(f"LZ4 output size mismatch: expected 0x{expected_size:X}, got 0x{len(output):X}")
        return output

    if data.startswith(LEGACY_LZ4_MAGIC):
        if expected_size is None:
            raise ValueError("Legacy LZ4 TZAR streams require an expected uncompressed size")
        block_size = struct.unpack_from("<I", data, 4)[0]
        block_start = 8
        block_end = block_start + block_size
        if block_end > len(data):
            raise ValueError("Legacy LZ4 block extends past input")
        if block_end != len(data) and not allow_trailing:
            raise ValueError("Legacy LZ4 input contains trailing data")
        output = lz4.block.decompress(data[block_start:block_end], uncompressed_size=expected_size)
        if len(output) != expected_size:
            raise ValueError(f"LZ4 output size mismatch: expected 0x{expected_size:X}, got 0x{len(output):X}")
        return output

    with tempfile.TemporaryDirectory() as td:
        in_path = Path(td) / "in.lz4"
        out_path = Path(td) / "out.bin"
        in_path.write_bytes(data)
        proc = run_lz4(["-d", "-f", str(in_path), str(out_path)], check=False)
        if proc.returncode != 0:
            if not allow_trailing or not out_path.exists():
                raise RuntimeError(proc.stderr.decode("utf-8", "replace").strip())
        output = out_path.read_bytes()
    if expected_size is not None and len(output) != expected_size:
        raise ValueError(f"LZ4 output size mismatch: expected 0x{expected_size:X}, got 0x{len(output):X}")
    return output


def lz4_compress(data, legacy=False, level="-12"):
    if legacy:
        block = lz4.block.compress(data, mode="high_compression", compression=12, store_size=False)
        return LEGACY_LZ4_MAGIC + struct.pack("<I", len(block)) + block
    if level == "-12":
        return lz4.frame.compress(data, compression_level=12)

    with tempfile.TemporaryDirectory() as td:
        in_path = Path(td) / "in.bin"
        out_path = Path(td) / "out.lz4"
        in_path.write_bytes(data)
        args = ["-f", level]
        if legacy:
            args.append("-l")
        args.extend([str(in_path), str(out_path)])
        run_lz4(args)
        return out_path.read_bytes()


def detect_container(data, requested):
    if requested != "auto":
        return requested
    if data.startswith(OUTER_LZ4_MAGIC):
        return "outer-lz4"
    if data.startswith(TZAR_MAGIC):
        return "startup"
    if len(data) >= 8 and data[4:8] == LEGACY_LZ4_MAGIC:
        return "wrapped"
    raise ValueError("Could not detect TZAR container type")


def read_input_image(path, container):
    source = Path(path)
    data = source.read_bytes()
    detected = detect_container(data, container)
    outer_lz4 = detected == "outer-lz4"
    if outer_lz4:
        wrapped = lz4_decompress(data)
    elif detected == "wrapped":
        wrapped = data
    elif detected == "startup":
        wrapped = None
    else:
        raise ValueError(f"Unsupported container type: {detected}")

    if wrapped is None:
        startup = data
        signed_size = None
        footer = None
    else:
        if len(wrapped) < 8 or wrapped[4:8] != LEGACY_LZ4_MAGIC:
            raise ValueError("Wrapped TZAR image does not contain the expected legacy-LZ4 startup stream")
        expected_size = struct.unpack_from("<I", wrapped, 0)[0]
        startup = lz4_decompress(wrapped[4:], allow_trailing=True, expected_size=expected_size)
        signed_size = len(wrapped)
        footer = parse_stage2_footer(wrapped, signed_size) if looks_like_stage2_footer(wrapped, signed_size) else None

    return {
        "source": source,
        "source_size": len(data),
        "container": detected,
        "outer_lz4": outer_lz4,
        "wrapped": wrapped,
        "startup": startup,
        "signed_size": signed_size,
        "footer": footer,
    }


def parse_startup_tzar(data):
    if len(data) < TZAR_HEADER_SIZE or data[:4] != TZAR_MAGIC:
        raise ValueError("Input is not a decompressed TEEgris startup TZAR")

    total_size = struct.unpack_from("<I", data, 8)[0]
    if total_size != len(data):
        raise ValueError(f"TZAR header size mismatch: header 0x{total_size:X}, actual 0x{len(data):X}")

    pos = TZAR_HEADER_SIZE
    records = []
    while pos < len(data):
        if pos + 8 > len(data):
            raise ValueError(f"Truncated TZAR record header at 0x{pos:X}")
        path_len, payload_size = struct.unpack_from("<II", data, pos)
        if path_len <= 1 or path_len > 0x1000:
            raise ValueError(f"Invalid path length {path_len} at 0x{pos:X}")
        path_start = pos + 8
        path_end = path_start + path_len
        payload_start = path_end
        payload_end = payload_start + payload_size
        if payload_end > len(data):
            raise ValueError(f"Record at 0x{pos:X} extends past TZAR end")
        path_raw = data[path_start:path_end]
        if not path_raw.endswith(b"\x00"):
            raise ValueError(f"Record path at 0x{pos:X} is not NUL terminated")
        path = path_raw[:-1].decode("utf-8")
        if not path.startswith("/"):
            raise ValueError(f"Record path at 0x{pos:X} is not absolute: {path}")
        payload = data[payload_start:payload_end]
        records.append({
            "index": len(records),
            "record_offset": pos,
            "path": path,
            "path_len": path_len,
            "size": payload_size,
            "payload_offset": payload_start,
            "payload_sha256": sha256(payload),
            "payload": payload,
        })
        records[-1]["startup_hash"] = startup_object_hash_hex(records[-1])
        pos = payload_end
    return records


def safe_output_path(base, archive_path):
    rel = archive_path.lstrip("/")
    parts = Path(rel).parts
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"Unsafe archive path: {archive_path}")
    return Path(base, *parts)


def footer_to_manifest(footer):
    if footer is None:
        return None
    return {
        "offset": footer.offset,
        "total_size": footer.total_size,
        "rp_count": footer.rp_count,
        "sign_type": footer.sign_type,
        "key_type": footer.key_type,
        "key_index": footer.key_index,
        "signature_offset": footer.signature_offset,
    }


def write_manifest(out_dir, image_info, startup, records):
    footer = image_info["footer"]
    manifest_records = []
    for record in records:
        manifest_records.append({
            "index": record["index"],
            "path": record["path"],
            "size": record["size"],
            "sha256": record["payload_sha256"],
            "startup_hash": record.get("startup_hash") or startup_object_hash_hex(record),
        })

    manifest = {
        "format": "teegris-startup-tzar-v1",
        "source": str(image_info["source"]),
        "source_container": image_info["container"],
        "source_size": image_info["source_size"],
        "startup": {
            "size": len(startup),
            "sha256": sha256(startup),
            "magic": startup[:4].hex(),
            "version_raw": startup[4:8].hex(),
            "unknown_0c": struct.unpack_from("<I", startup, 12)[0],
        },
        "wrapped_image": {
            "present": image_info["wrapped"] is not None,
            "size": image_info["signed_size"],
            "stage2_footer": footer_to_manifest(footer),
        },
        "outer_lz4": image_info["outer_lz4"],
        "records": manifest_records,
    }
    Path(out_dir, MANIFEST_NAME).write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest
