# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Umer Uddin <umer.uddin@mentallysanemainliners.org>
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
#
# Modified from the original Tonasket work by Umer Uddin.

import os

import argparse

import hmac
import hashlib

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

from common import DEFAULT_SOC, SOC_HELP, generate_padded_pub_key, get_soc_config

HMAC_SIZE = 0x20


def generate_private_key(private_key_path, key_name):
    print(f"Generating {key_name} private key")
    print()

    private_key = ec.generate_private_key(ec.SECP384R1(), default_backend())
    public_key = private_key.public_key()

    private_pem = private_key.private_bytes(encoding=serialization.Encoding.PEM,
                                            format=serialization.PrivateFormat.PKCS8,
                                            encryption_algorithm=serialization.NoEncryption())

    print(f"Saving {key_name} private key")
    with open(private_key_path, 'wb') as f:
        f.write(private_pem)
        f.close()

    print(f"{key_name} private key saved to: {private_key_path}")
    print()
    return public_key


def save_pubkey_blob(public_key, output_path, key_name, soc_config):
    pubkey_blob = generate_padded_pub_key(public_key, soc_config["name"])

    with open(output_path, 'wb') as f:
        f.write(pubkey_blob)
        f.close()

    print(f"{key_name} public key blob saved to: {output_path}")
    print()


def compute_pubkey_hmac(pubkey_blob, output_prefix, soc_config):
    hmac_key = os.urandom(HMAC_SIZE)

    # HMAC X and Y
    pubkey_for_hmac = pubkey_blob[:soc_config["pubkey_hmac_size"]]
    hmac_result = hmac.new(hmac_key, pubkey_for_hmac, hashlib.sha512).digest()[:HMAC_SIZE]

    with open(f"{output_prefix}.hmac", 'wb') as f:
        f.write(hmac_result)
        f.close()

    print(f"HMAC data saved to {output_prefix}.hmac")

    return hmac_key, hmac_result


def generate_efuse_data(public_key, output_prefix, soc_config):
    print("Generating efuse & hmac data")

    pubkey_blob = generate_padded_pub_key(public_key, soc_config["name"])

    hmac_key, hmac_result = compute_pubkey_hmac(pubkey_blob, output_prefix, soc_config)

    efuse_buf = bytes(a ^ b for a, b in zip(hmac_key, hmac_result))

    with open(f"{output_prefix}.efuse", 'wb') as f:
        f.write(efuse_buf)
        f.close()

    print(f"Efuse data saved to {output_prefix}.efuse")
    print()


def output_paths(output_prefix):
    return [
        f"{output_prefix}_private.pem",
        f"{output_prefix}.hmac",
        f"{output_prefix}.efuse",
        f"{output_prefix}_stage2_tee_private.pem",
        f"{output_prefix}_stage2_tee_pubkey.bin",
        f"{output_prefix}_stage2_ree_private.pem",
        f"{output_prefix}_stage2_ree_pubkey.bin",
        f"{output_prefix}_stage3_private.pem",
        f"{output_prefix}_stage3_pubkey.bin",
    ]


def refuse_overwrite(output_prefix):
    existing_files = [path for path in output_paths(output_prefix) if os.path.exists(path)]

    if existing_files:
        print("Key files already exist! Refusing to overwrite:")
        for path in existing_files:
            print(f"  {path}")
        exit(-1)


def main():
    print("2024-56426 Key Generation Utility")
    parser = argparse.ArgumentParser(description="BL1 sign key generator")
    parser.add_argument('-o', '--output-prefix', type=str, help="Output file prefix", required=True)
    parser.add_argument('--soc', type=str, default=DEFAULT_SOC, help=SOC_HELP)

    args = parser.parse_args()

    try:
        soc_config = get_soc_config(args.soc)
    except ValueError as e:
        parser.error(str(e))

    print(f"Target SoC: {soc_config['display_name']}")
    print()

    refuse_overwrite(args.output_prefix)

    bl1_pubkey = generate_private_key(f"{args.output_prefix}_private.pem", "BL1 signing")
    generate_efuse_data(bl1_pubkey, args.output_prefix, soc_config)

    tee_pubkey = generate_private_key(f"{args.output_prefix}_stage2_tee_private.pem", "Stage2 TEE")
    save_pubkey_blob(tee_pubkey, f"{args.output_prefix}_stage2_tee_pubkey.bin", "Stage2 TEE", soc_config)

    ree_pubkey = generate_private_key(f"{args.output_prefix}_stage2_ree_private.pem", "Stage2 REE")
    save_pubkey_blob(ree_pubkey, f"{args.output_prefix}_stage2_ree_pubkey.bin", "Stage2 REE", soc_config)

    stage3_pubkey = generate_private_key(f"{args.output_prefix}_stage3_private.pem", "Stage3")
    save_pubkey_blob(stage3_pubkey, f"{args.output_prefix}_stage3_pubkey.bin", "Stage3", soc_config)

    print("Generated signer inputs:")
    print(f"  --soc {soc_config['name']}")
    print(f"  -k  {args.output_prefix}_private.pem")
    print(f"  -H  {args.output_prefix}.hmac")
    print(f"  -t  {args.output_prefix}_stage2_tee_pubkey.bin")
    print(f"  -re {args.output_prefix}_stage2_ree_pubkey.bin")
    print()
    print("Generated Stage3 inputs:")
    print(f"  private: {args.output_prefix}_stage3_private.pem")
    print(f"  public:  {args.output_prefix}_stage3_pubkey.bin")
    print()
    print("PLEASE keep all of these safe, make backups NOW.")


if __name__ == "__main__":
    main()
