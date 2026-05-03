#!/usr/bin/env python3

import argparse
import hashlib
import shutil
import struct
import subprocess
from pathlib import Path

DEFAULT_KEY = bytes.fromhex("45F5A2F3F2E8C5C234DF481A3D6697FE30244C2F173DC773AC6BDD24087B638E")
DEFAULT_IV = bytes.fromhex("069F3C80DFBAC1AF5DF0C557712DFE38")

DEFAULT_LOAD_ADDR = 0x02026000
DEFAULT_PTR_REGION_START_OFF = 0x02031D28 - DEFAULT_LOAD_ADDR  # 0xBD28
DEFAULT_PTR_REGION_END_OFF = 0x02031D50 - DEFAULT_LOAD_ADDR  # 0xBD50

DEFAULT_FALLBACK_REGION_START = 0x16D0
DEFAULT_FALLBACK_REGION_END = 0xBCB0

HEADER_SIZE = 16
BLOCK_SIZE = 512
EPBL_MAGIC = 0x68656164  # "head"


def _aes_cbc_crypto(data: bytes, key: bytes, iv: bytes, decrypt: bool) -> bytes:
    from Crypto.Cipher import AES  # type: ignore

    cipher = AES.new(key, AES.MODE_CBC, iv)
    return cipher.decrypt(data) if decrypt else cipher.encrypt(data)


def _aes_cbc_cryptodome(data: bytes, key: bytes, iv: bytes, decrypt: bool) -> bytes:
    from Cryptodome.Cipher import AES  # type: ignore

    cipher = AES.new(key, AES.MODE_CBC, iv)
    return cipher.decrypt(data) if decrypt else cipher.encrypt(data)


def _aes_cbc_openssl(data: bytes, key: bytes, iv: bytes, decrypt: bool) -> bytes:
    openssl = shutil.which("openssl")
    if not openssl:
        raise RuntimeError("openssl binary not found in PATH")

    cmd = [
        openssl,
        "enc",
        "-aes-256-cbc",
        "-K",
        key.hex(),
        "-iv",
        iv.hex(),
        "-nopad",
        "-nosalt",
    ]
    if decrypt:
        cmd.append("-d")

    proc = subprocess.run(cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"openssl failed ({proc.returncode}): {err}")
    return proc.stdout


def select_aes_backend():
    backends = [
        ("pycrypto/pycryptodome (Crypto)", _aes_cbc_crypto),
        ("pycryptodomex (Cryptodome)", _aes_cbc_cryptodome),
        ("openssl", _aes_cbc_openssl),
    ]

    probe = b"\x00" * 16
    key = b"\x00" * 32
    iv = b"\x00" * 16
    errors = []

    for name, fn in backends:
        try:
            out = fn(probe, key, iv, False)
            if len(out) != len(probe):
                raise RuntimeError(f"probe returned {len(out)} bytes, expected {len(probe)}")
            return name, fn
        except Exception as exc:
            errors.append(f"{name}: {exc}")

    joined = "; ".join(errors)
    raise RuntimeError(f"no working AES backend found ({joined})")


def parse_int(s: str) -> int:
    return int(s, 0)


def parse_hex_bytes(hex_s: str, expected_len: int, label: str) -> bytes:
    raw = bytes.fromhex(hex_s)
    if len(raw) != expected_len:
        raise ValueError(f"{label} must be {expected_len} bytes (got {len(raw)})")
    return raw


def patch_epbl_header(img: bytearray) -> tuple[int, int]:
    if len(img) < HEADER_SIZE:
        raise ValueError(f"file too small ({len(img)} bytes)")
    if len(img) % BLOCK_SIZE != 0:
        raise ValueError(f"file size {len(img)} is not {BLOCK_SIZE}-byte aligned")

    blocks = len(img) // BLOCK_SIZE
    hash_word0 = struct.unpack("<I", hashlib.sha512(img[HEADER_SIZE:]).digest()[:4])[0]

    img[0:4] = struct.pack("<I", blocks)
    img[4:8] = struct.pack("<I", hash_word0)
    img[8:12] = struct.pack("<I", EPBL_MAGIC)
    img[12:16] = b"\x00" * 4
    return blocks, hash_word0


def read_u64_le(buf: bytes, off: int) -> int:
    if off < 0 or off + 8 > len(buf):
        raise ValueError(f"u64 read out of range at offset 0x{off:X}")
    return struct.unpack("<Q", buf[off:off + 8])[0]


def resolve_region_from_pointers(
        img: bytes,
        *,
        load_addr: int,
        ptr_start_off: int,
        ptr_end_off: int,
) -> tuple[int, int]:
    start_ptr = read_u64_le(img, ptr_start_off)
    end_ptr = read_u64_le(img, ptr_end_off)

    if start_ptr < load_addr or end_ptr < load_addr:
        raise ValueError(
            f"pointer region invalid: start_ptr=0x{start_ptr:X} end_ptr=0x{end_ptr:X} "
            f"load_addr=0x{load_addr:X}"
        )

    start = start_ptr - load_addr
    end = end_ptr - load_addr
    return start, end


def validate_region(img_len: int, start: int, end: int) -> int:
    if start < 0 or end < 0 or start >= end:
        raise ValueError(f"bad region: start=0x{start:X} end=0x{end:X}")
    if end > img_len:
        raise ValueError(
            f"region out of file: start=0x{start:X} end=0x{end:X} file_size=0x{img_len:X}"
        )
    region_len = end - start
    if region_len % 16 != 0:
        raise ValueError(
            f"region length must be AES-CBC block aligned (16): 0x{region_len:X}"
        )
    return region_len


def build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Re-encrypt EPBL image region (AES-CBC), with optional header patch."
    )
    p.add_argument("-i", "--input", type=Path, default=Path("epbl.img.dec"))
    p.add_argument("-o", "--output", type=Path, default=Path("epbl.img.reenc"))
    p.add_argument("--load-addr", type=parse_int, default=DEFAULT_LOAD_ADDR)
    p.add_argument(
        "--key",
        default=DEFAULT_KEY.hex(),
        help="AES-256 key hex (default: known Exynos9830 EPBL key)",
    )
    p.add_argument(
        "--iv",
        default=DEFAULT_IV.hex(),
        help="AES-CBC IV hex (default: known Exynos9830 EPBL IV)",
    )

    p.add_argument("--region-start", type=parse_int, default=None)
    p.add_argument("--region-end", type=parse_int, default=None)

    p.add_argument(
        "--ptr-region-start-off",
        type=parse_int,
        default=DEFAULT_PTR_REGION_START_OFF,
        help="offset of encrypted-region-start VA pointer (u64 LE)",
    )
    p.add_argument(
        "--ptr-region-end-off",
        type=parse_int,
        default=DEFAULT_PTR_REGION_END_OFF,
        help="offset of encrypted-region-end VA pointer (u64 LE)",
    )

    p.add_argument("--fallback-region-start", type=parse_int, default=DEFAULT_FALLBACK_REGION_START)
    p.add_argument("--fallback-region-end", type=parse_int, default=DEFAULT_FALLBACK_REGION_END)
    p.add_argument(
        "--force-fallback-region",
        action="store_true",
        help="ignore pointer fields and always use fallback region",
    )

    p.add_argument(
        "--no-roundtrip-verify",
        action="store_true",
        help="skip decrypt(encrypt(plain)) integrity check",
    )
    p.add_argument(
        "--no-update-header",
        action="store_true",
        help="do not recompute EPBL header hash/magic fields",
    )
    return p


def main() -> int:
    args = build_argparser().parse_args()

    key = parse_hex_bytes(args.key, 32, "key")
    iv = parse_hex_bytes(args.iv, 16, "iv")
    aes_backend_name, aes_cbc = select_aes_backend()

    data = bytearray(args.input.read_bytes())

    if (args.region_start is None) ^ (args.region_end is None):
        raise ValueError("use both --region-start and --region-end or neither")

    region_source = "explicit"
    if args.region_start is not None:
        start = args.region_start
        end = args.region_end
    elif args.force_fallback_region:
        region_source = "fallback"
        start = args.fallback_region_start
        end = args.fallback_region_end
    else:
        try:
            start, end = resolve_region_from_pointers(
                data,
                load_addr=args.load_addr,
                ptr_start_off=args.ptr_region_start_off,
                ptr_end_off=args.ptr_region_end_off,
            )
            region_source = "pointers"
        except Exception as exc:
            print(f"[warn] pointer-based region resolution failed: {exc}")
            start = args.fallback_region_start
            end = args.fallback_region_end
            region_source = "fallback"

    region_len = validate_region(len(data), start, end)

    print("EPBL information:")
    print()
    print(f"input: {args.input}")
    print(f"output: {args.output}")
    print(f"load address: 0x{args.load_addr:X}")
    print(f"region source: {region_source}")
    print(f"encrypted region start: 0x{start:X}")
    print(f"encrypted region end: 0x{end:X}")
    print(f"encrypted region size: 0x{region_len:X}")
    print()
    print(f"AES key: {key.hex()}")
    print(f"IV: {iv.hex()}")
    print(f"AES backend: {aes_backend_name}")
    print()

    plaintext = bytes(data[start:end])
    ciphertext = aes_cbc(plaintext, key, iv, False)
    data[start:end] = ciphertext

    if not args.no_roundtrip_verify:
        verify = aes_cbc(ciphertext, key, iv, True)
        if verify != plaintext:
            raise RuntimeError("roundtrip verify failed: decrypted(ciphertext) != plaintext")
        print("roundtrip verify: OK")

    if not args.no_update_header:
        blocks, hash_word0 = patch_epbl_header(data)
        print(f"header patched: blocks={blocks} hash32=0x{hash_word0:08X} magic=0x{EPBL_MAGIC:08X}")
    else:
        print("header patch: skipped (--no-update-header)")

    args.output.write_bytes(data)
    print(f"re-encrypted EPBL written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
