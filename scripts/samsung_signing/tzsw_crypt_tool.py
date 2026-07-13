#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import hashlib
from pathlib import Path

from aes_cbc import select_aes_backend
from binary_io import read_u32

MASTER_KEY = bytes.fromhex("E83420592B7FC371C6734501C767D38E982C6584B1518E1C450A362A57F1C50E")
MASTER_IV = bytes.fromhex("C3471249DDF13D50180AB6C8A9589294")
USERBOOT_HASH_MARKER = b"ub_tzar_walk_cb\x00"
AES_BLOCK_SIZE = 16


AES_BACKEND_NAME, aes_cbc = select_aes_backend(AES_BLOCK_SIZE)


def tzsw_region(data: bytes | bytearray) -> tuple[int, int]:
    if len(data) < 0x70:
        raise ValueError("tzsw.img is too small for the Exynos9830 TZSW crypto header")
    start = read_u32(data, 0x28)
    end = read_u32(data, 0x2C)
    if start >= end or end > len(data):
        raise ValueError(f"Invalid TZSW encrypted region: start=0x{start:X} end=0x{end:X} image=0x{len(data):X}")
    if (end - start) % AES_BLOCK_SIZE:
        raise ValueError(f"TZSW encrypted region is not AES-block aligned: size=0x{end - start:X}")
    return start, end


def tzsw_key(data: bytes | bytearray) -> bytes:
    key, _ = tzsw_key_bundle(data)
    return key


def tzsw_iv(data: bytes | bytearray) -> bytes:
    _, iv = tzsw_key_bundle(data)
    return iv


def tzsw_encrypted_iv(data: bytes | bytearray) -> bytes:
    return bytes(data[0x60:0x70])


def tzsw_key_bundle(data: bytes | bytearray) -> tuple[bytes, bytes]:
    if len(data) < 0x90:
        raise ValueError("tzsw.img is too small for the Exynos9830 TZSW crypto header")
    # The per-image key and IV are stored as an encrypted header bundle and are
    # decrypted with the fixed Exynos9830 master key/IV.
    bundle = aes_cbc(bytes(data[0x40:0x70]), MASTER_KEY, MASTER_IV, True)
    return bundle[:0x20], bundle[0x20:0x30]


def tzsw_stored_digest(data: bytes | bytearray) -> bytes:
    if len(data) < 0x90:
        raise ValueError("tzsw.img is too small for the Exynos9830 TZSW crypto header")
    return bytes(data[0x70:0x90])


def tzsw_plain_digest(data: bytes | bytearray) -> bytes:
    start, end = tzsw_region(data)
    return hashlib.sha256(bytes(data[start:end])).digest()


def update_tzsw_digest(data: bytes | bytearray) -> bytes:
    out = bytearray(data)
    out[0x70:0x90] = tzsw_plain_digest(out)
    return bytes(out)


def verify_tzsw_digest(data: bytes | bytearray) -> bool:
    return tzsw_stored_digest(data) == tzsw_plain_digest(data)


def is_clear_tzsw(data: bytes | bytearray) -> bool:
    return USERBOOT_HASH_MARKER in data


def transform_tzsw(data: bytes | bytearray, *, decrypt: bool) -> bytes:
    start, end = tzsw_region(data)
    key = tzsw_key(data)
    iv = tzsw_iv(data)
    out = bytearray(data)
    block = bytes(out[start:end])
    out[start:end] = aes_cbc(block, key, iv, decrypt)
    return bytes(out)


def decrypt_tzsw(data: bytes | bytearray) -> bytes:
    return transform_tzsw(data, decrypt=True)


def encrypt_tzsw(data: bytes | bytearray) -> bytes:
    # The stored BiEn digest covers the clear encrypted region, so refresh it
    # before transforming the region back to ciphertext.
    return transform_tzsw(update_tzsw_digest(data), decrypt=False)


def command_status(args: argparse.Namespace) -> None:
    data = Path(args.input).read_bytes()
    start, end = tzsw_region(data)
    clear = data if is_clear_tzsw(data) else decrypt_tzsw(data)
    stored_digest = tzsw_stored_digest(data)
    calculated_digest = tzsw_plain_digest(clear)
    print(f"Input: {args.input}")
    print(f"Region: 0x{start:X}-0x{end:X} size=0x{end - start:X}")
    print(f"Key: {tzsw_key(data).hex()}")
    print(f"IV: {tzsw_iv(data).hex()}")
    print(f"Encrypted IV field: {tzsw_encrypted_iv(data).hex()}")
    print(f"Stored digest: {stored_digest.hex()}")
    print(f"Calculated digest: {calculated_digest.hex()}")
    print(f"Digest valid: {'yes' if stored_digest == calculated_digest else 'no'}")
    print(f"Clear marker: {'yes' if is_clear_tzsw(data) else 'no'}")


def command_decrypt(args: argparse.Namespace) -> None:
    data = Path(args.input).read_bytes()
    out = decrypt_tzsw(data)
    if args.require_marker and not is_clear_tzsw(out):
        raise ValueError("Decrypted TZSW does not contain the expected userboot hash marker")
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_bytes(out)
    print(f"Decrypted TZSW written to {args.output}")


def command_encrypt(args: argparse.Namespace) -> None:
    data = Path(args.input).read_bytes()
    if args.require_marker and not is_clear_tzsw(data):
        raise ValueError("Input TZSW does not contain the expected clear userboot hash marker")
    fixed = update_tzsw_digest(data)
    out = transform_tzsw(fixed, decrypt=False)
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_bytes(out)
    print(f"Updated TZSW BiEn digest: {tzsw_stored_digest(fixed).hex()}")
    print(f"Encrypted TZSW written to {args.output}")


def command_update_digest(args: argparse.Namespace) -> None:
    data = Path(args.input).read_bytes()
    if args.require_marker and not is_clear_tzsw(data):
        raise ValueError("Input TZSW does not contain the expected clear userboot hash marker")
    out = update_tzsw_digest(data)
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_bytes(out)
    print(f"Updated TZSW BiEn digest: {tzsw_stored_digest(out).hex()}")
    print(f"Digest-patched TZSW written to {args.output}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Decrypt or recrypt Exynos9830 tzsw.img payloads")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="Print TZSW crypto header info")
    status.add_argument("-i", "--input", required=True)
    status.set_defaults(func=command_status)

    decrypt = sub.add_parser("decrypt", help="Decrypt the TZSW encrypted region")
    decrypt.add_argument("-i", "--input", required=True)
    decrypt.add_argument("-o", "--output", required=True)
    decrypt.add_argument("--no-require-marker", dest="require_marker", action="store_false")
    decrypt.set_defaults(func=command_decrypt, require_marker=True)

    encrypt = sub.add_parser("encrypt", help="Encrypt the TZSW clear region")
    encrypt.add_argument("-i", "--input", required=True)
    encrypt.add_argument("-o", "--output", required=True)
    encrypt.add_argument("--no-require-marker", dest="require_marker", action="store_false")
    encrypt.set_defaults(func=command_encrypt, require_marker=True)

    update_digest = sub.add_parser("update-digest", help="Update the clear TZSW BiEn SHA-256 digest")
    update_digest.add_argument("-i", "--input", required=True)
    update_digest.add_argument("-o", "--output", required=True)
    update_digest.add_argument("--no-require-marker", dest="require_marker", action="store_false")
    update_digest.set_defaults(func=command_update_digest, require_marker=True)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
