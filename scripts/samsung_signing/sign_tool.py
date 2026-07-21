# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Umer Uddin <umer.uddin@mentallysanemainliners.org>
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
#
# Modified from the original Tonasket work by Umer Uddin.

import os
import time

import argparse

import struct

import hashlib

from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import utils
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from binary_io import write_u32
from common import *

BLOCK_SIZE = 512
HMAC_SIZE = 0x20

BL1_HEADER_SIZE = 0x0010
BL1_FOOTER_OFFSET = 0x0930
BL1_SOC_INFO_OFFSET = BL1_FOOTER_OFFSET + 0x0008


def write_u16(value):
    return struct.pack('<H', value)


def write_u64(value):
    return struct.pack('<Q', value)


def pack_evt(evt_str):
    return bytes(int(d) for d in evt_str[::-1])


def write_soc_info(bl1, soc_info_off, evt, machine_id, soc_config):
    if soc_config["soc_info_format"] == "packed_evt_machine":
        bl1[soc_info_off:soc_info_off + 2] = pack_evt(evt)
        bl1[soc_info_off + 2:soc_info_off + 4] = write_u16(machine_id)
    elif soc_config["soc_info_format"] == "plain_machine":
        bl1[soc_info_off:soc_info_off + 4] = write_u32(machine_id)
    else:
        raise ValueError(f"Unsupported SoC info format: {soc_config['soc_info_format']}")

    bl1[soc_info_off + 4:soc_info_off + 8] = write_u32(soc_config["soc_info_word"])


def create_partial_footer(bl1, evt, machine_id, rp_count, stagetwo_tee_key, stagetwo_ree_key, model_id, bl1_pub_key,
                          hmac, soc_config):
    bl1_size = len(bl1)
    soc_info_off = bl1_size - BL1_SOC_INFO_OFFSET
    footer_off = bl1_size - BL1_FOOTER_OFFSET

    # BL1 stores its signer footer relative to the padded output size, not the
    # original fwbl1 input length.
    write_soc_info(bl1, soc_info_off, evt, machine_id, soc_config)

    bl1[footer_off:footer_off + 4] = write_u32(5)  # Signer Version
    bl1[footer_off + 4:footer_off + 8] = write_u32(0x49534C53)  # AP Info, SLSI
    bl1[footer_off + 8:footer_off + 16] = write_u64(int(time.time()))  # Sign timestamp
    bl1[footer_off + 16:footer_off + 20] = write_u32(rp_count)
    bl1[footer_off + 20:footer_off + 24] = write_u32(4)  # Sign Type, ECDSA_P_NIST_384
    bl1[footer_off + 24:footer_off + 92] = b"\x00" * 68
    bl1[footer_off + 92:footer_off + 616] = stagetwo_tee_key
    bl1[footer_off + 616:footer_off + 1140] = stagetwo_ree_key
    bl1[footer_off + 1140:footer_off + 1268] = b"\x00" * 128
    bl1[footer_off + 1268:footer_off + 1272] = write_u32(model_id)
    bl1[footer_off + 1272:footer_off + 1280] = b"\x00" * 8
    bl1[footer_off + 1280:footer_off + 1804] = bl1_pub_key
    bl1[footer_off + 1804:footer_off + 1836] = hmac
    bl1[footer_off + 1836:footer_off + 1840] = write_u32(136)
    bl1[footer_off + 1840:footer_off + 2352] = b"\x00" * 512


def process_header(bl1, size):
    bl1_block_size = size // 512

    # The header hash is cleared before signing, then filled with the final
    # digest prefix after the footer signature is inserted.
    bl1[0:4] = write_u32(bl1_block_size)
    bl1[4:8] = write_u32(0)  # We have to clear the hash to sign properly


def read_bl1_input(bl1_path, size):
    with open(bl1_path, 'rb') as f:
        data = f.read(size + 1)

    if len(data) > size:
        raise ValueError(f"BL1 input exceeds the requested output size of {size} bytes")

    return data


def sign_bl1(bl1_path, output_path, size, private_key_path, evt, machine_id, rp_count, stagetwo_tee_key_path,
             stagetwo_ree_key_path, model_id, hmac_path, soc_config):
    data = read_bl1_input(bl1_path, size)
    bl1_file = bytearray(size)
    signature_offset = size - BL1_FOOTER_OFFSET + 1840

    with open(private_key_path, 'rb') as f:
        private_key = serialization.load_pem_private_key(f.read(), password=None)

    public_key = private_key.public_key()
    padded_pub_key = generate_padded_pub_key(public_key, soc_config["name"])

    bl1_file[:len(data)] = data

    with open(hmac_path, 'rb') as f:
        hmac = f.read()
        f.close()

    with open(stagetwo_tee_key_path, 'rb') as f:
        stagetwo_tee_key = f.read()
        f.close()

    with open(stagetwo_ree_key_path, 'rb') as f:
        stagetwo_ree_key = f.read()
        f.close()

    if len(hmac) != HMAC_SIZE:
        raise ValueError(f"HMAC must be {HMAC_SIZE} bytes, got {len(hmac)}")

    if len(stagetwo_tee_key) != soc_config["pubkey_blob_size"]:
        raise ValueError(f"Stage2 TEE public key blob must be {soc_config['pubkey_blob_size']} bytes")

    if len(stagetwo_ree_key) != soc_config["pubkey_blob_size"]:
        raise ValueError(f"Stage2 REE public key blob must be {soc_config['pubkey_blob_size']} bytes")

    print("Creating minimal header")
    process_header(bl1_file, size)

    print("Creating partial footer")
    print()
    create_partial_footer(bl1_file, evt, machine_id, rp_count, stagetwo_tee_key, stagetwo_ree_key, model_id,
                          padded_pub_key, hmac, soc_config)

    hash_data = bytes(bl1_file[:signature_offset])
    digest = hashlib.sha512(hash_data).digest()

    print(f"SHA-512 Digest: {digest.hex()}")
    print()

    signature = private_key.sign(digest, ec.ECDSA(utils.Prehashed(hashes.SHA512())))

    r, s = decode_dss_signature(signature)
    sig_blob = generate_padded_signature(r, s, soc_config["name"])

    print("Inserting signature into footer")
    print()
    bl1_file[signature_offset:signature_offset + 512] = sig_blob

    print("SHA-512 Hashing BL1")
    print()
    hash_data = bytes(bl1_file[BL1_HEADER_SIZE:size])
    digest = hashlib.sha512(hash_data).digest()

    print(f"Final hash: {digest.hex()}")
    print()

    print("Inserting hash into header")
    print()
    bl1_file[0x04:0x08] = struct.pack('<I', struct.unpack('<I', digest[:4])[0])

    with open(output_path, 'wb') as f:
        f.write(bl1_file)
        f.close()

    print(f"Signing finished, signed BL1 is at {output_path}")


def main():
    print("2024-56426 Signing Utility")
    print()

    parser = argparse.ArgumentParser(description="BL1 signer")
    parser.add_argument("--soc", type=str, default=DEFAULT_SOC, help=SOC_HELP)
    parser.add_argument('-i', '--input', type=str, help="Path to unsigned BL1 input", required=True)
    parser.add_argument("-o", "--output", type=str, help="Path to signed BL1 output", required=True)
    parser.add_argument("-k", "--key-file", type=str, default=DEFAULT_BL1_PRIVATE_KEY,
                        help=f"Path to the private key to sign BL1 with. Default: {DEFAULT_BL1_PRIVATE_KEY}")
    parser.add_argument("-H", "--hmac", type=str, default=DEFAULT_BL1_HMAC,
                        help=f"Path to the HMAC file to put into BL1. Default: {DEFAULT_BL1_HMAC}")
    parser.add_argument("-s", "--size", type=lambda x: int(x, 0),
                        help="Size of the BL1 output (has to be divisible by 512), for example 0x3000", required=True)
    parser.add_argument("-e", "--evt", type=str,
                        help="Two digit EVT Version for SoC, e.g. 11 for EVT1.1. "
                             "Required for exynos990/exynos9830; not stored for exynos9820.")
    parser.add_argument("-r", "--rp-cnt", type=lambda x: int(x, 0), help="Rollback counter for BL1", required=True)
    parser.add_argument("-t", "--tee-pub-key", type=str, default=DEFAULT_STAGE2_TEE_PUBKEY,
                        help=f"Path to the Stage2 TEE public key blob. Default: {DEFAULT_STAGE2_TEE_PUBKEY}")
    parser.add_argument("-re", "--ree-pub-key", type=str, default=DEFAULT_STAGE2_REE_PUBKEY,
                        help=f"Path to the Stage2 REE public key blob. Default: {DEFAULT_STAGE2_REE_PUBKEY}")
    parser.add_argument("-m", "--model-id", type=lambda x: int(x, 0),
                        help="Model ID (e.g. 0x13D for Samsung Galaxy S20 5G)", required=True)
    parser.add_argument("-ma", "--machine-id", type=lambda x: int(x, 0),
                        help="Machine ID. Defaults to the selected SoC machine ID.")
    args = parser.parse_args()

    try:
        soc_config = get_soc_config(args.soc)
    except ValueError as e:
        parser.error(str(e))

    machine_id = args.machine_id if args.machine_id is not None else soc_config["machine_id"]

    for file in [args.input, args.key_file, args.hmac, args.tee_pub_key, args.ree_pub_key]:
        if not os.path.isfile(file):
            print(f"Missing file: {file}")
            exit(-1)

    if args.size < BL1_FOOTER_OFFSET + 2352:
        print("Size is too small for footer!")
        exit(-1)

    if args.size % 512 != 0:
        print("Size is not divisible by 512!")
        exit(-1)

    if soc_config["requires_evt"] and args.evt is None:
        parser.error("--evt is required for the selected SoC")

    if args.evt is not None:
        if not args.evt.isdigit():
            raise ValueError("EVT must be numeric")

        if len(args.evt) != 2:
            raise ValueError("EVT must be exactly 2 digits")

    if machine_id < 0 or machine_id > 0xFFFF:
        raise ValueError("Machine ID must fit in 16 bits")

    print(f"Target SoC: {soc_config['display_name']}")
    print(f"Machine ID: 0x{machine_id:04X}")
    if soc_config["requires_evt"]:
        print(f"EVT: {args.evt}")
    elif args.evt is not None:
        print("EVT is not stored for this SoC; ignoring --evt")
    print()

    try:
        sign_bl1(args.input, args.output, args.size, args.key_file, args.evt, machine_id, args.rp_cnt,
                 args.tee_pub_key, args.ree_pub_key, args.model_id, args.hmac, soc_config)
    except ValueError as e:
        parser.error(str(e))


if __name__ == "__main__":
    main()
