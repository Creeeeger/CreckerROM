# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Umer Uddin <umer.uddin@mentallysanemainliners.org>
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
#
# Modified from the original Tonasket work by Umer Uddin.

DEFAULT_SOC = "exynos990"

DEFAULT_KEY_PREFIX = "crecker"
DEFAULT_BL1_PRIVATE_KEY = f"{DEFAULT_KEY_PREFIX}_private.pem"
DEFAULT_BL1_HMAC = f"{DEFAULT_KEY_PREFIX}.hmac"
DEFAULT_STAGE2_TEE_PRIVATE_KEY = f"{DEFAULT_KEY_PREFIX}_stage2_tee_private.pem"
DEFAULT_STAGE2_TEE_PUBKEY = f"{DEFAULT_KEY_PREFIX}_stage2_tee_pubkey.bin"
DEFAULT_STAGE2_REE_PRIVATE_KEY = f"{DEFAULT_KEY_PREFIX}_stage2_ree_private.pem"
DEFAULT_STAGE2_REE_PUBKEY = f"{DEFAULT_KEY_PREFIX}_stage2_ree_pubkey.bin"
DEFAULT_STAGE3_PRIVATE_KEY = f"{DEFAULT_KEY_PREFIX}_stage3_private.pem"
DEFAULT_STAGE3_PUBKEY = f"{DEFAULT_KEY_PREFIX}_stage3_pubkey.bin"

SOC_CONFIGS = {
    "exynos990": {
        "name": "exynos990",
        "display_name": "Exynos 990 / Exynos9830",
        "machine_id": 0x9830,
        "soc_info_format": "packed_evt_machine",
        "soc_info_word": 0x19091613,
        "requires_evt": True,
        "ecdsa_coord_size": 48,
        "ecdsa_field_size": 68,
        "pubkey_blob_size": 0x20C,
        "pubkey_hmac_size": 0x88,
        "signature_blob_size": 0x200,
    },
    "exynos9820": {
        "name": "exynos9820",
        "display_name": "Exynos 9820",
        "machine_id": 0x9820,
        "soc_info_format": "plain_machine",
        "soc_info_word": 0x18110718,
        "requires_evt": False,
        "ecdsa_coord_size": 48,
        "ecdsa_field_size": 68,
        "pubkey_blob_size": 0x20C,
        "pubkey_hmac_size": 0x88,
        "signature_blob_size": 0x200,
    },
}

SOC_ALIASES = {
    "exynos990": "exynos990",
    "exynos9830": "exynos990",
    "990": "exynos990",
    "9830": "exynos990",
    "exynos9820": "exynos9820",
    "9820": "exynos9820",
}

SOC_HELP = "Target SoC: exynos990/exynos9830 or exynos9820"


def normalize_soc(soc):
    soc_key = soc.lower().replace("_", "").replace("-", "")
    if soc_key not in SOC_ALIASES:
        known = ", ".join(sorted(SOC_ALIASES.keys()))
        raise ValueError(f"Unknown SoC '{soc}'. Known values: {known}")

    return SOC_ALIASES[soc_key]


def get_soc_config(soc):
    return SOC_CONFIGS[normalize_soc(soc)]


def generate_padded_pub_key(public_key, soc=DEFAULT_SOC):
    soc_config = get_soc_config(soc)
    coord_size = soc_config["ecdsa_coord_size"]
    field_size = soc_config["ecdsa_field_size"]

    public_numbers = public_key.public_numbers()
    x = public_numbers.x.to_bytes(coord_size, byteorder='big')
    y = public_numbers.y.to_bytes(coord_size, byteorder='big')

    x_padded = b'\x00' * (field_size - coord_size) + x
    y_padded = b'\x00' * (field_size - coord_size) + y

    pubkey_blob = x_padded + y_padded
    pubkey_blob += b'\x00' * (soc_config["pubkey_blob_size"] - len(pubkey_blob))

    return pubkey_blob


def generate_padded_signature(r, s, soc=DEFAULT_SOC):
    soc_config = get_soc_config(soc)
    coord_size = soc_config["ecdsa_coord_size"]
    field_size = soc_config["ecdsa_field_size"]

    r_bytes = r.to_bytes(coord_size, byteorder='big')
    s_bytes = s.to_bytes(coord_size, byteorder='big')

    r_padded = b'\x00' * (field_size - coord_size) + r_bytes
    s_padded = b'\x00' * (field_size - coord_size) + s_bytes

    sig_blob = r_padded + s_padded
    sig_blob += b'\x00' * (soc_config["signature_blob_size"] - len(sig_blob))

    return sig_blob
