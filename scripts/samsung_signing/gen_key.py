# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Umer Uddin <umer.uddin@mentallysanemainliners.org>
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
# Adapted from the CVE-2024-56426 key generator.

import argparse
import hashlib
import hmac
import os
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from common import DEFAULT_SOC, SOC_HELP, generate_padded_pub_key, get_soc_config
from key_bundle import validate_key_bundle

KEY_SLOTS = ("stage2_tee", "stage2_ree", "stage3")


def generate_artifacts(output_prefix: Path, soc: str = DEFAULT_SOC,
                       slots: tuple[str, ...] = KEY_SLOTS) -> dict[Path, tuple[bytes, int]]:
    config = get_soc_config(soc)
    prefix = str(output_prefix)
    private = ec.generate_private_key(ec.SECP384R1())
    hmac_key = os.urandom(32)
    public = generate_padded_pub_key(private.public_key(), soc)
    auth_hash = hmac.new(hmac_key, public[:config["pubkey_hmac_size"]], hashlib.sha512).digest()[:32]

    def private_pem(key):
        return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                 serialization.NoEncryption())

    artifacts = {
        Path(f"{prefix}_private.pem"): (private_pem(private), 0o600),
        Path(f"{prefix}.hmac"): (auth_hash, 0o600),
        Path(f"{prefix}.efuse"): (bytes(a ^ b for a, b in zip(hmac_key, auth_hash)), 0o600),
    }
    for slot in slots:
        if slot not in KEY_SLOTS:
            raise ValueError(f"Unknown signing key slot: {slot}")
        key = ec.generate_private_key(ec.SECP384R1())
        artifacts[Path(f"{prefix}_{slot}_private.pem")] = (private_pem(key), 0o600)
        artifacts[Path(f"{prefix}_{slot}_pubkey.bin")] = (generate_padded_pub_key(key.public_key(), soc), 0o644)
    return artifacts


def write_artifacts(artifacts: dict[Path, tuple[bytes, int]]) -> None:
    existing = [path for path in artifacts if os.path.lexists(path)]
    if existing:
        raise FileExistsError("Key files already exist; refusing to overwrite: " + ", ".join(map(str, existing)))
    created = []
    try:
        for path, (data, mode) in artifacts.items():
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
            created.append(path)
            with os.fdopen(descriptor, "wb") as output:
                output.write(data)
    except BaseException:
        for path in created:
            path.unlink()
        raise


def main():
    parser = argparse.ArgumentParser(description="Generate a complete Samsung BL1/Stage2/Stage3 signing bundle")
    parser.add_argument("-o", "--output-prefix", type=Path, required=True, help="New directory and /crecker prefix")
    parser.add_argument("--soc", default=DEFAULT_SOC, help=SOC_HELP)
    args = parser.parse_args()
    if args.output_prefix.name != "crecker":
        parser.error("--output-prefix must end in /crecker so the signing tools can use the bundle")
    try:
        get_soc_config(args.soc)
        args.output_prefix.parent.mkdir(parents=True, exist_ok=True)
        artifacts = generate_artifacts(args.output_prefix, args.soc)
        write_artifacts(artifacts)
        try:
            validate_key_bundle(args.output_prefix.parent, args.soc)
        except BaseException:
            for path in artifacts:
                path.unlink()
            raise
    except (ValueError, OSError) as error:
        parser.exit(1, f"Key generation failed: {error}\n")
    print(f"Generated and validated {len(artifacts)} files in {args.output_prefix.parent}")
    print(f"Select this bundle explicitly with --keys-dir {args.output_prefix.parent.resolve()}")
    print("For coordinated ROM key rotation, use ./regenerate_keys.sh instead.")


if __name__ == "__main__":
    main()
