#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only

import shutil
import subprocess
from collections.abc import Callable


AesCbcFunction = Callable[[bytes, bytes, bytes, bool], bytes]


def _aes_cbc_cryptography(data: bytes, key: bytes, iv: bytes, decrypt: bool) -> bytes:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    operation = cipher.decryptor() if decrypt else cipher.encryptor()
    return operation.update(data) + operation.finalize()


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

    proc = subprocess.run(
        cmd,
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"openssl failed ({proc.returncode}): {err}")
    return proc.stdout


def select_aes_backend(block_size: int = 16) -> tuple[str, AesCbcFunction]:
    backends = [
        ("cryptography", _aes_cbc_cryptography),
        ("openssl", _aes_cbc_openssl),
    ]

    probe = b"\x00" * block_size
    key = b"\x00" * 32
    iv = b"\x00" * block_size
    errors = []

    for name, function in backends:
        try:
            output = function(probe, key, iv, False)
            if len(output) != len(probe):
                raise RuntimeError(
                    f"probe returned {len(output)} bytes, expected {len(probe)}"
                )
            return name, function
        except Exception as exc:
            errors.append(f"{name}: {exc}")

    joined = "; ".join(errors)
    raise RuntimeError(f"no working AES backend found ({joined})")
