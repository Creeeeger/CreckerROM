# SPDX-License-Identifier: GPL-2.0-only
# Adapted from CVE-2024-56426 external/tools/key_bundle.py.
"""Validate a complete Samsung signing bundle before using any of its keys."""

import hashlib
import hmac
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from common import DEFAULT_SOC, generate_padded_pub_key, get_soc_config

KEY_FILENAMES = {
    "bl1_private": "crecker_private.pem",
    "bl1_hmac": "crecker.hmac",
    "efuse": "crecker.efuse",
    "stage2_tee_private": "crecker_stage2_tee_private.pem",
    "stage2_tee_pub": "crecker_stage2_tee_pubkey.bin",
    "stage2_ree_private": "crecker_stage2_ree_private.pem",
    "stage2_ree_pub": "crecker_stage2_ree_pubkey.bin",
    "stage3_private": "crecker_stage3_private.pem",
    "stage3_pub": "crecker_stage3_pubkey.bin",
}


def public_blob(private_key_path: Path, soc: str) -> bytes:
    private = serialization.load_pem_private_key(private_key_path.read_bytes(), password=None)
    if not isinstance(private, ec.EllipticCurvePrivateKey) or not isinstance(private.curve, ec.SECP384R1):
        raise ValueError(f"Expected a P-384 private key: {private_key_path}")
    return generate_padded_pub_key(private.public_key(), soc)


def validate_key_bundle(keys_dir: Path, soc: str = DEFAULT_SOC) -> dict[str, Path]:
    paths = {name: Path(keys_dir) / filename for name, filename in KEY_FILENAMES.items()}
    missing = [path for path in paths.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError("Missing key bundle files: " + ", ".join(map(str, missing)))

    config = get_soc_config(soc)
    bl1_public = public_blob(paths["bl1_private"], soc)
    auth_hash = paths["bl1_hmac"].read_bytes()
    efuse = paths["efuse"].read_bytes()
    if len(auth_hash) != 32 or len(efuse) != 32:
        raise ValueError("crecker.hmac and crecker.efuse must both be exactly 32 bytes")
    hmac_key = bytes(a ^ b for a, b in zip(auth_hash, efuse))
    expected = hmac.new(hmac_key, bl1_public[:config["pubkey_hmac_size"]], hashlib.sha512).digest()[:32]
    if not hmac.compare_digest(auth_hash, expected):
        raise ValueError("BL1 private key, HMAC, and eFuse context do not match")

    for slot in ("stage2_tee", "stage2_ree", "stage3"):
        expected = public_blob(paths[f"{slot}_private"], soc)
        if not hmac.compare_digest(expected, paths[f"{slot}_pub"].read_bytes()):
            raise ValueError(f"{slot} private and public keys do not match")
    return paths
