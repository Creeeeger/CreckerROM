# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

import hashlib
import struct
from dataclasses import dataclass
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.utils import (
    decode_dss_signature,
    encode_dss_signature,
)

from common import (
    DEFAULT_SOC,
    DEFAULT_STAGE2_REE_PRIVATE_KEY,
    DEFAULT_STAGE2_REE_PUBKEY,
    DEFAULT_STAGE2_TEE_PRIVATE_KEY,
    DEFAULT_STAGE2_TEE_PUBKEY,
    generate_padded_signature,
    get_soc_config,
)

STAGE2_FOOTER_HEADER_SIZE = 0x10
STAGE2_SIGNATURE_SIZE = 0x200
STAGE2_FOOTER_SIZE = STAGE2_FOOTER_HEADER_SIZE + STAGE2_SIGNATURE_SIZE

EPBL_HEADER_SIZE = 0x10
EPBL_MAGIC_OFFSET = 0x08
EPBL_MAGIC = 0x68656164

AVB_FOOTER_SIZE = 0x40
AVB_FOOTER_MAGIC = b"AVBf"

SIGN_TYPE_ECDSA_NIST_P384 = 4
DEFAULT_KEY_INDEX = 0x01B94633

STAGE_TYPES = {
    "bl2": 0,
    "lk": 1,
    "el3": 2,
    "el3_mon": 2,
    "keystorage": 3,
    "ldfw": 4,
    "tzsw": 5,
    "secureos": 5,
    "secure_os": 5,
    "epbl": None,
    "harx": 6,
    "h_arx": 6,
    "spayload": 7,
    "tzar": 8,
    "uh": 9,
    "plugin": 9,
    "greentea": 9,
    "modem": 0x0E,
    "cp_boot": 0x0E,
    "cp_main": 0x0E,
    "modem_boot": 0x0E,
    "modem_main": 0x0E,
    "boot": 0x10,
    "recovery": 0x11,
    "dtbo": 0x12,
    "sboot": 0x13,
    "bootloader": 0x13,
    "misc": 0x14,
    "vbmeta": 0x15,
    "vbmeta_samsung": 0x16,
    "vendor_boot": 0x17,
    "init_boot": 0x18,
}

STAGE_DEFAULT_KEY_TYPES = {
    "epbl": 0,
    "bl2": 1,
    "lk": 1,
    "el3": 0,
    "el3_mon": 0,
    "keystorage": 0,
    "ldfw": 0,
    "tzsw": 0,
    "secureos": 0,
    "secure_os": 0,
    "harx": 0,
    "h_arx": 0,
    "spayload": 0,
    "tzar": 0,
    "uh": 0,
    "plugin": 0,
    "greentea": 0,
    "modem": 2,
    "cp_boot": 2,
    "cp_main": 2,
    "modem_boot": 2,
    "modem_main": 2,
    "boot": 0,
    "recovery": 0,
    "dtbo": 0,
    "sboot": 0,
    "bootloader": 0,
    "misc": 0,
    "vbmeta": 0,
    "vbmeta_samsung": 0,
    "vendor_boot": 0,
    "init_boot": 0,
}

AVB_WRAPPER_STAGES = {
    "tzsw",
    "secureos",
    "secure_os",
    "ldfw",
    "keystorage",
    "harx",
    "h_arx",
    "boot",
    "recovery",
    "dtbo",
    "sboot",
    "bootloader",
    "vendor_boot",
    "init_boot",
}


@dataclass
class Stage2Footer:
    offset: int
    total_size: int
    rp_count: int
    sign_type: int
    key_type: int
    key_index: int

    @property
    def signature_offset(self):
        return self.offset + STAGE2_FOOTER_HEADER_SIZE

    @property
    def digest_end(self):
        return self.total_size - STAGE2_SIGNATURE_SIZE


@dataclass
class AvbFooter:
    original_image_size: int
    vbmeta_offset: int
    vbmeta_size: int


@dataclass
class SignTarget:
    name: str
    total_size: int
    zero_epbl_checksum: bool = False
    update_epbl_checksum: bool = False


def read_file(path):
    return Path(path).read_bytes()


def write_file(path, data):
    Path(path).write_bytes(data)


def read_u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def write_u32(value):
    return struct.pack("<I", value)


def normalize_stage(stage):
    key = stage.lower().replace("-", "_")
    if key not in STAGE_TYPES:
        known = ", ".join(sorted(STAGE_TYPES))
        raise ValueError(f"Unknown stage '{stage}'. Known stages: {known}")
    return key


def stage_type(stage):
    return STAGE_TYPES[normalize_stage(stage)]


def default_key_type(stage):
    return STAGE_DEFAULT_KEY_TYPES[normalize_stage(stage)]


def is_p384_private_key(private_key):
    return isinstance(getattr(private_key, "curve", None), ec.SECP384R1)


def default_private_key_for_key_type(key_type):
    if key_type == 0:
        return DEFAULT_STAGE2_TEE_PRIVATE_KEY
    if key_type == 1:
        return DEFAULT_STAGE2_REE_PRIVATE_KEY
    raise ValueError(f"No default private key is configured for key_type {key_type}; pass -k/--key-file")


def is_avb_wrapper_stage(stage):
    return normalize_stage(stage) in AVB_WRAPPER_STAGES


def effective_verify_key_type(stage, footer_key_type):
    stype = stage_type(stage)
    if stype is None:
        return 0
    if 2 <= stype <= 5:
        return 0
    return footer_key_type


def parse_stage2_footer(data, total_size):
    if total_size < STAGE2_FOOTER_SIZE or total_size > len(data):
        raise ValueError("Image is too small for a Stage-2 footer at the requested size")

    offset = total_size - STAGE2_FOOTER_SIZE
    return Stage2Footer(
        offset=offset,
        total_size=total_size,
        rp_count=read_u32(data, offset),
        sign_type=read_u32(data, offset + 4),
        key_type=read_u32(data, offset + 8),
        key_index=read_u32(data, offset + 12),
    )


def write_stage2_footer_header(data, total_size, rp_count, sign_type, key_type, key_index):
    footer = parse_stage2_footer(data, total_size)
    data[footer.offset:footer.offset + 4] = write_u32(rp_count)
    data[footer.offset + 4:footer.offset + 8] = write_u32(sign_type)
    data[footer.offset + 8:footer.offset + 12] = write_u32(key_type)
    data[footer.offset + 12:footer.offset + 16] = write_u32(key_index)
    return parse_stage2_footer(data, total_size)


def parse_avb_footer(data):
    if len(data) < AVB_FOOTER_SIZE:
        return None

    footer = data[-AVB_FOOTER_SIZE:]
    if footer[:4] != AVB_FOOTER_MAGIC:
        return None

    return AvbFooter(
        original_image_size=struct.unpack_from(">Q", footer, 12)[0],
        vbmeta_offset=struct.unpack_from(">Q", footer, 20)[0],
        vbmeta_size=struct.unpack_from(">Q", footer, 28)[0],
    )


def epbl_total_size_from_header(data):
    if len(data) < EPBL_HEADER_SIZE:
        raise ValueError("EPBL image is too small for its header")
    if read_u32(data, EPBL_MAGIC_OFFSET) != EPBL_MAGIC:
        raise ValueError("EPBL magic at offset 0x08 is not 'head'")

    sectors = read_u32(data, 0)
    if sectors <= 2:
        raise ValueError("EPBL sector count is invalid")

    total_size = sectors * 512
    if total_size > len(data):
        raise ValueError("EPBL header size is larger than the input file")
    return total_size


def update_epbl_header(data, total_size):
    if total_size % 512 != 0:
        raise ValueError("EPBL size must be divisible by 512")
    if total_size > len(data):
        raise ValueError("EPBL total size is larger than the output buffer")

    data[0:4] = write_u32(total_size // 512)
    if read_u32(data, EPBL_MAGIC_OFFSET) != EPBL_MAGIC:
        data[EPBL_MAGIC_OFFSET:EPBL_MAGIC_OFFSET + 4] = write_u32(EPBL_MAGIC)


def compute_digest(data, total_size, zero_epbl_checksum=False):
    digest_end = total_size - STAGE2_SIGNATURE_SIZE
    if digest_end <= 0:
        raise ValueError("Stage-2 digest range is empty")

    digest_data = bytearray(data[:digest_end])
    if zero_epbl_checksum:
        if len(digest_data) < EPBL_HEADER_SIZE:
            raise ValueError("EPBL digest range is too small")
        digest_data[4:8] = b"\x00" * 4

    return hashlib.sha512(bytes(digest_data)).digest()


def update_epbl_checksum(data, total_size):
    digest = hashlib.sha512(bytes(data[EPBL_HEADER_SIZE:total_size])).digest()
    data[4:8] = digest[:4]
    return digest


def load_private_key(path):
    with open(path, "rb") as f:
        return serialization.load_pem_private_key(f.read(), password=None, backend=default_backend())


def load_pubkey_blob(path, soc=DEFAULT_SOC):
    blob = read_file(path)
    soc_config = get_soc_config(soc)
    expected = soc_config["pubkey_blob_size"]
    if len(blob) != expected:
        raise ValueError(f"Public key blob must be {expected} bytes, got {len(blob)}")
    return blob


def public_key_from_blob(pubkey_blob, soc=DEFAULT_SOC):
    soc_config = get_soc_config(soc)
    field_size = soc_config["ecdsa_field_size"]
    coord_size = soc_config["ecdsa_coord_size"]

    if len(pubkey_blob) < field_size * 2:
        raise ValueError("Public key blob is too short")

    x = int.from_bytes(pubkey_blob[field_size - coord_size:field_size], "big")
    y_start = field_size
    y = int.from_bytes(pubkey_blob[y_start + field_size - coord_size:y_start + field_size], "big")
    return ec.EllipticCurvePublicNumbers(x, y, ec.SECP384R1()).public_key(default_backend())


def padded_signature_to_der(sig_blob, soc=DEFAULT_SOC):
    soc_config = get_soc_config(soc)
    field_size = soc_config["ecdsa_field_size"]
    coord_size = soc_config["ecdsa_coord_size"]
    expected = soc_config["signature_blob_size"]

    if len(sig_blob) != expected:
        raise ValueError(f"Signature blob must be {expected} bytes, got {len(sig_blob)}")

    r = int.from_bytes(sig_blob[field_size - coord_size:field_size], "big")
    s_start = field_size
    s = int.from_bytes(sig_blob[s_start + field_size - coord_size:s_start + field_size], "big")
    return encode_dss_signature(r, s)


def sign_digest(private_key, digest, soc=DEFAULT_SOC):
    signature = private_key.sign(digest, ec.ECDSA(utils.Prehashed(hashes.SHA512())))
    r, s = decode_dss_signature(signature)
    return generate_padded_signature(r, s, soc)


def verify_digest(pubkey_blob, sig_blob, digest, soc=DEFAULT_SOC):
    public_key = public_key_from_blob(pubkey_blob, soc)
    signature = padded_signature_to_der(sig_blob, soc)
    try:
        public_key.verify(signature, digest, ec.ECDSA(utils.Prehashed(hashes.SHA512())))
        return True
    except InvalidSignature:
        return False


def signature_blob(data, footer):
    return bytes(data[footer.signature_offset:footer.signature_offset + STAGE2_SIGNATURE_SIZE])


def looks_like_stage2_footer(data, total_size):
    try:
        footer = parse_stage2_footer(data, total_size)
    except ValueError:
        return False

    sig = signature_blob(data, footer)
    return (
            footer.rp_count < 0x81
            and 0 <= footer.key_type <= 2
            and 3 <= footer.sign_type <= 8
            and footer.key_index != 0
            and sig != b"\x00" * STAGE2_SIGNATURE_SIZE
    )


def signer_info_offset_from_avb_original(data, original_image_size):
    metadata_offset = original_image_size - STAGE2_FOOTER_SIZE - 0x100
    if metadata_offset < 0 or metadata_offset + 0x100 > len(data):
        return None
    if data[metadata_offset:metadata_offset + 9] == b"SignerVer":
        return metadata_offset
    return None


def stage2_footer_candidate_sizes(stage, data):
    sizes = []
    stage = normalize_stage(stage)

    if is_avb_wrapper_stage(stage):
        avb = parse_avb_footer(data)
        if avb is not None and avb.original_image_size <= len(data):
            if looks_like_stage2_footer(data, avb.original_image_size):
                sizes.append(avb.original_image_size)
            signer_info_offset = signer_info_offset_from_avb_original(data, avb.original_image_size)
            if signer_info_offset is not None and looks_like_stage2_footer(data, signer_info_offset):
                sizes.append(signer_info_offset)

    if looks_like_stage2_footer(data, len(data)):
        sizes.append(len(data))

    deduped = []
    for size in sizes:
        if size not in deduped:
            deduped.append(size)
    return deduped


def validate_signing_args(args, parser, key_type_label="--key-type"):
    if args.rp_cnt < 0 or args.rp_cnt >= 0x81:
        parser.error("--rp-cnt must be in range 0..0x80")
    if args.sign_type != SIGN_TYPE_ECDSA_NIST_P384:
        parser.error("Only sign_type 4 (ECDSA NIST P-384) is implemented")
    if args.key_type is not None and not 0 <= args.key_type <= 2:
        parser.error(f"{key_type_label} must be 0, 1, or 2")
    if args.key_index is not None and args.key_index == 0:
        parser.error("--key-index must be non-zero")


def load_stage2_key_map(args, soc):
    if getattr(args, "pub_key", None):
        blob = load_pubkey_blob(args.pub_key, soc)
        return {0: blob, 1: blob, 2: blob}

    key_map = {}
    tee_pub_key = getattr(args, "tee_pub_key", None)
    ree_pub_key = getattr(args, "ree_pub_key", None)
    stage3_pub_key = getattr(args, "stage3_pub_key", None)
    if tee_pub_key:
        key_map[0] = load_pubkey_blob(tee_pub_key, soc)
    if ree_pub_key:
        key_map[1] = load_pubkey_blob(ree_pub_key, soc)
    if stage3_pub_key:
        key_map[2] = load_pubkey_blob(stage3_pub_key, soc)
    return key_map


def add_stage2_pubkey_args(parser):
    parser.add_argument("-p", "--pub-key", help="Single public key blob to use for all key types")
    parser.add_argument("--tee-pub-key", default=DEFAULT_STAGE2_TEE_PUBKEY,
                        help=f"Stage-2 TEE public key blob. Default: {DEFAULT_STAGE2_TEE_PUBKEY}")
    parser.add_argument("--ree-pub-key", default=DEFAULT_STAGE2_REE_PUBKEY,
                        help=f"Stage-2 REE public key blob. Default: {DEFAULT_STAGE2_REE_PUBKEY}")
    parser.add_argument("--stage3-pub-key", help="Optional key_type 2 public key blob")
