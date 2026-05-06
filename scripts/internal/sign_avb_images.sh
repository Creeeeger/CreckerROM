#!/usr/bin/env bash
#
# Copyright (C) 2026
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#

# [
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

TMP_IMG_DIR="$1"
TMP_DIR="${TMP_DIR:-$OUT_DIR/tmp}"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_CSC="$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_MODEL_ALT="${TARGET_FIRMWARE_MODEL#SM-}"
PACK_DIR="${TARGET_AVB_IMAGE_PACK_DIR:-$OUT_DIR/target/$TARGET_CODENAME/signed_images}"
PACK_ZIP="${TARGET_AVB_IMAGE_PACK_ZIP:-$OUT_DIR/${TARGET_CODENAME}_signed_images.zip}"
TARGET_ENABLE_SAMSUNG_SIGNING="${TARGET_ENABLE_SAMSUNG_SIGNING:-false}"
TARGET_SAMSUNG_SIGN_BOOTLOADER="${TARGET_SAMSUNG_SIGN_BOOTLOADER:-$TARGET_ENABLE_SAMSUNG_SIGNING}"
TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR="${TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR:-$OUT_DIR/target/$TARGET_CODENAME/signed_bootloader}"
mkdir -p "$TMP_DIR" || exit 1
STAGING_DIR="$(mktemp -d "$TMP_DIR/avb_sign.XXXXXX")" || exit 1
DEFAULT_CUSTOM_AVB_KEY_DIR="$SRC_DIR/security/avb"
DEFAULT_CUSTOM_AVB_KEY_NAME="creckerrom_avb"
DEFAULT_CUSTOM_AVB_KEY_PATH="$DEFAULT_CUSTOM_AVB_KEY_DIR/${DEFAULT_CUSTOM_AVB_KEY_NAME}_private.pem"
UPSTREAM_AVBTOOL_PATH="$SRC_DIR/platform_external_avb-master/avbtool.py"
DIRECT_DESCRIPTOR_IMAGES=""
ACTIVE_CHAIN_PARTITIONS=""
ORIGINAL_HASH_PARTITIONS=""
ORIGINAL_HASHTREE_PARTITIONS=""
ORIGINAL_CHAIN_PARTITIONS=""
ORIGINAL_VBMETA_PROPS=""
ORIGINAL_VBMETA_ALGORITHM=""
ORIGINAL_VBMETA_ROLLBACK_INDEX=""
ORIGINAL_VBMETA_ROLLBACK_INDEX_LOCATION=""
ORIGINAL_VBMETA_RELEASE_STRING=""
ORIGINAL_VBMETA_KERNEL_CMDLINE_COUNT=0
ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE="$STAGING_DIR/original_vbmeta_kernel_cmdlines.tsv"
ORIGINAL_VBMETA_TRAILER_PATH=""
ORIGINAL_VBMETA_TRAILER_SIZE="0"
ORIGINAL_VBMETA_TRAILER_MARKER=""
ORIGINAL_VBMETA_SAMSUNG_PROPS=""
ORIGINAL_VBMETA_SAMSUNG_ALGORITHM=""
ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX=""
ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX_LOCATION=""
ORIGINAL_VBMETA_SAMSUNG_RELEASE_STRING=""
ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH=""
ORIGINAL_VBMETA_SAMSUNG_TRAILER_SIZE="0"
ORIGINAL_VBMETA_SAMSUNG_TRAILER_MARKER=""
VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS=""
HASH_PARTITIONS=""
HASHTREE_PARTITIONS=""
CHAIN_PARTITIONS=""
AVBTOOL_PATH=""
AVB_PYTHON_BIN=""
AVBTOOL_CMD=()
SIGNED_PARTITIONS=""
VBMETA_SIGN_KEY_PATH=""
VBMETA_SIGN_ALGORITHM=""
PARTITION_SIGN_KEY_PATH=""
PARTITION_SIGN_ALGORITHM=""
PARTITION_SIGN_HASH_ALGORITHM=""
PARTITION_SIGN_ROLLBACK_INDEX=""
PARTITION_SIGN_ROLLBACK_INDEX_LOCATION=""
PARTITION_SIGN_DO_NOT_USE_AB="false"
PARTITION_SIGN_EXTRA_ARGS=""
KEY_EXPORT_LABELS=""
KEY_EXPORT_REPORT="$STAGING_DIR/avb_keys.txt"
FIRMWARE_DESCRIPTOR_PACK_FILES=""
FIRMWARE_DESCRIPTOR_PACK_COMPONENTS=""
EXCLUDED_VBMETA_PARTITIONS="bootloader"
REQUIRED_RE_SIGN_PARTITIONS="boot init_boot vendor_boot dtbo recovery"
INCLUDED_HASH_PARTITIONS=""
INCLUDED_HASHTREE_PARTITIONS=""
INCLUDED_CHAIN_PARTITIONS=""
# ]

LIST_HAS_ITEM()
{
    local ITEM="$1"
    local LIST="$2"
    local ENTRY

    for ENTRY in $LIST; do
        [ "$ENTRY" = "$ITEM" ] && return 0
    done

    return 1
}

APPEND_UNIQUE()
{
    local VAR_NAME="$1"
    local ITEM="$2"
    local CURRENT

    eval "CURRENT=\${$VAR_NAME}"
    LIST_HAS_ITEM "$ITEM" "$CURRENT" && return 0

    if [ -n "$CURRENT" ]; then
        eval "$VAR_NAME=\"\$CURRENT \$ITEM\""
    else
        eval "$VAR_NAME=\"\$ITEM\""
    fi
}

REMOVE_ITEM()
{
    local VAR_NAME="$1"
    local ITEM="$2"
    local CURRENT
    local UPDATED=""
    local ENTRY

    eval "CURRENT=\${$VAR_NAME}"

    for ENTRY in $CURRENT; do
        [ "$ENTRY" = "$ITEM" ] && continue

        if [ -n "$UPDATED" ]; then
            UPDATED="$UPDATED $ENTRY"
        else
            UPDATED="$ENTRY"
        fi
    done

    eval "$VAR_NAME=\"\$UPDATED\""
}

REMOVE_KV_ITEM()
{
    local VAR_NAME="$1"
    local KEY="$2"
    local CURRENT
    local UPDATED=""
    local ENTRY

    eval "CURRENT=\${$VAR_NAME}"

    for ENTRY in $CURRENT; do
        [ "${ENTRY%%=*}" = "$KEY" ] && continue

        if [ -n "$UPDATED" ]; then
            UPDATED="$UPDATED $ENTRY"
        else
            UPDATED="$ENTRY"
        fi
    done

    eval "$VAR_NAME=\"\$UPDATED\""
}

SET_PARTITION_SIGN_KIND()
{
    local PARTITION="$1"
    local KIND="$2"

    REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
    REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"

    if [ "$KIND" = "hashtree" ]; then
        APPEND_UNIQUE "HASHTREE_PARTITIONS" "$PARTITION"
    else
        APPEND_UNIQUE "HASH_PARTITIONS" "$PARTITION"
    fi
}

GET_KV_VALUE()
{
    local KEY="$1"
    local LIST="$2"
    local ENTRY
    local VALUE=""

    for ENTRY in $LIST; do
        [ "${ENTRY%%=*}" = "$KEY" ] && VALUE="${ENTRY#*=}"
    done

    [ -n "$VALUE" ] && echo "$VALUE"
}

APPEND_ARGS_FROM_STRING()
{
    local ARRAY_NAME="$1"
    local VALUE="$2"
    local PARSED_ARGS=()

    [ -n "$VALUE" ] || return 0

    # Values come from trusted target config shell variables and may rely on
    # normal shell quoting semantics.
    eval "PARSED_ARGS=( $VALUE )"
    eval "$ARRAY_NAME+=(\"\${PARSED_ARGS[@]}\")"
}

GET_ENV_VALUE()
{
    local VAR_NAME="$1"
    local VALUE=""

    eval "VALUE=\${$VAR_NAME:-}"
    [ -n "$VALUE" ] && [ "$VALUE" != "none" ] && echo "$VALUE"
}

GET_PARTITION_VAR_VALUE()
{
    local PARTITION="$1"
    local SUFFIX="$2"
    local VAR_NAME

    VAR_NAME="TARGET_AVB_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_${SUFFIX}"
    GET_ENV_VALUE "$VAR_NAME"
}

GET_CHAIN_LOCATION()
{
    local PARTITION="$1"
    local VALUE=""

    VALUE="$(GET_KV_VALUE "$PARTITION" "$CHAIN_PARTITIONS")"
    [ -n "$VALUE" ] && echo "$VALUE"
}

IS_EXCLUDED_AVB_PARTITION()
{
    local PARTITION="$1"

    LIST_HAS_ITEM "$PARTITION" "$EXCLUDED_VBMETA_PARTITIONS"
}

IS_AVB_DEBUG_ENABLED()
{
    [ "${DEBUG:-false}" = "true" ]
}

AVB_DEBUG_LOG()
{
    local INDENT="${INDENT_LEVEL:=0}"

    IS_AVB_DEBUG_ENABLED || return 0
    printf "%*s- [AVB debug] %s\n" "$INDENT" "" "$1" >&2
}

FORMAT_COMMAND()
{
    local OUTPUT=""
    local ARG

    for ARG in "$@"; do
        if [ -n "$OUTPUT" ]; then
            OUTPUT+=" "
        fi
        OUTPUT+="$(printf '%q' "$ARG")"
    done

    printf '%s' "$OUTPUT"
}

LOG_PARTITION_SET()
{
    local LABEL="$1"
    local VALUE="$2"

    AVB_DEBUG_LOG "$LABEL: ${VALUE:-<empty>}"
}

INIT_DEFAULTS()
{
    TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT="${TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT:-true}"
    TARGET_AVB_KEY_PATH="${TARGET_AVB_KEY_PATH:-$DEFAULT_CUSTOM_AVB_KEY_PATH}"
    case "$TARGET_AVB_KEY_PATH" in
        "auto_aosp_platform" | "$OUT_DIR/security/aosp_platform_avb.pem" | */aosp_platform_avb.pem)
            LOGW "AOSP AVB key fallback is no longer used. Switching to generated custom AVB key at $DEFAULT_CUSTOM_AVB_KEY_PATH"
            TARGET_AVB_KEY_PATH="$DEFAULT_CUSTOM_AVB_KEY_PATH"
            ;;
    esac
    if [ -z "${TARGET_AVB_ALGORITHM:-}" ] || \
            { [ "$TARGET_AVB_KEY_PATH" = "$DEFAULT_CUSTOM_AVB_KEY_PATH" ] && [ "$TARGET_AVB_ALGORITHM" = "SHA256_RSA2048" ]; }; then
        TARGET_AVB_ALGORITHM="SHA256_RSA4096"
    fi
    TARGET_AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-$UPSTREAM_AVBTOOL_PATH}"
    TARGET_AVBTOOL_PYTHON="${TARGET_AVBTOOL_PYTHON:-none}"
    TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS="${TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS:-true}"
    TARGET_AVB_HASH_PARTITIONS="${TARGET_AVB_HASH_PARTITIONS:-}"
    TARGET_AVB_HASHTREE_PARTITIONS="${TARGET_AVB_HASHTREE_PARTITIONS:-}"
    TARGET_AVB_CHAIN_PARTITIONS="${TARGET_AVB_CHAIN_PARTITIONS:-}"
    TARGET_AVB_ORIGINAL_VBMETA_PATH="${TARGET_AVB_ORIGINAL_VBMETA_PATH:-none}"
    TARGET_AVB_ALLOW_HASHTREE_FALLBACK="${TARGET_AVB_ALLOW_HASHTREE_FALLBACK:-false}"
    TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL="${TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL:-1}"
    TARGET_AVB_CREATE_IMAGE_PACK_ZIP="${TARGET_AVB_CREATE_IMAGE_PACK_ZIP:-false}"
    TARGET_AVB_ROLLBACK_INDEX="${TARGET_AVB_ROLLBACK_INDEX:-0}"
    TARGET_AVB_ROLLBACK_INDEX_LOCATION="${TARGET_AVB_ROLLBACK_INDEX_LOCATION:-0}"
    TARGET_AVB_HASH_ALGORITHM="${TARGET_AVB_HASH_ALGORITHM:-sha256}"
    TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS="${TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS:-}"
    TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS="${TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS:-}"
    TARGET_AVB_FIRMWARE_IMAGE_MAP="${TARGET_AVB_FIRMWARE_IMAGE_MAP:-}"
    TARGET_AVB_USE_ORIGINAL_VBMETA_PROPS="${TARGET_AVB_USE_ORIGINAL_VBMETA_PROPS:-true}"
    TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES="${TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES:-true}"
    TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH="${TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH:-none}"
    TARGET_AVB_VBMETA_SAMSUNG_PARTITIONS="${TARGET_AVB_VBMETA_SAMSUNG_PARTITIONS:-odm product system vendor}"
    TARGET_AVB_MAKE_VBMETA_SAMSUNG_IMAGE_ARGS="${TARGET_AVB_MAKE_VBMETA_SAMSUNG_IMAGE_ARGS:-}"

    if ! [[ "$TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL" =~ ^[0-9]$ ]]; then
        LOGW "Invalid TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL: $TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL (expected 0-9). Using 1."
        TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL="1"
    fi
    if [ "$TARGET_AVB_CREATE_IMAGE_PACK_ZIP" != "true" ] && [ "$TARGET_AVB_CREATE_IMAGE_PACK_ZIP" != "false" ]; then
        LOGW "Invalid TARGET_AVB_CREATE_IMAGE_PACK_ZIP: $TARGET_AVB_CREATE_IMAGE_PACK_ZIP (expected true|false). Using false."
        TARGET_AVB_CREATE_IMAGE_PACK_ZIP="false"
    fi
    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ] && [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "false" ]; then
        LOGW "Invalid TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS: $TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS (expected true|false). Using true."
        TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS="true"
    fi
    if [ "$TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES" != "true" ] && [ "$TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES" != "false" ]; then
        LOGW "Invalid TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES: $TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES (expected true|false). Using true."
        TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES="true"
    fi
}

GET_FALLBACK_HASH_PARTITIONS()
{
    echo "boot vendor_boot init_boot recovery"
}

GET_FALLBACK_HASHTREE_PARTITIONS()
{
    echo "system vendor product odm system_ext vendor_dlkm odm_dlkm system_dlkm prism optics"
}

GET_FALLBACK_CHAIN_PARTITIONS()
{
    echo "dtbo=7 prism=12 optics=13"
}

GET_ORIGINAL_VBMETA_SAMSUNG_PATH()
{
    if [ "$TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH" != "none" ] && [ -f "$TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH" ]; then
        echo "$TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH"
    elif [ -f "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta_samsung.img" ]; then
        echo "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta_samsung.img"
    fi
}

GET_ORIGINAL_VBMETA_PATH()
{
    if [ "$TARGET_AVB_ORIGINAL_VBMETA_PATH" != "none" ] && [ -f "$TARGET_AVB_ORIGINAL_VBMETA_PATH" ]; then
        echo "$TARGET_AVB_ORIGINAL_VBMETA_PATH"
    elif [ -f "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta.img" ]; then
        echo "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta.img"
    elif [ -f "$SRC_DIR/../vbmeta.img" ]; then
        echo "$SRC_DIR/../vbmeta.img"
    fi
}

PARSE_ORIGINAL_VBMETA_LAYOUT()
{
    local ORIGINAL_VBMETA
    local KIND
    local KEY
    local VALUE
    local TRAILER_INFO=""
    local TRAILER_OFFSET=""
    local TRAILER_SIZE=""
    local TRAILER_MARKER=""

    $TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT || return 0

    ORIGINAL_VBMETA="$(GET_ORIGINAL_VBMETA_PATH)"
    [ -f "$ORIGINAL_VBMETA" ] || return 0
    [ -n "$AVB_PYTHON_BIN" ] || return 0
    [ -f "$AVBTOOL_PATH" ] || return 0
    : > "$ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE"

    DUMP_AVB_INFO_IMAGE "$ORIGINAL_VBMETA" "original vbmeta"

    while IFS=$'\t' read -r KIND KEY VALUE; do
        case "$KIND" in
            "meta_algorithm")
                ORIGINAL_VBMETA_ALGORITHM="$KEY"
                ;;
            "meta_rollback_index")
                ORIGINAL_VBMETA_ROLLBACK_INDEX="$KEY"
                ;;
            "meta_rollback_index_location")
                ORIGINAL_VBMETA_ROLLBACK_INDEX_LOCATION="$KEY"
                ;;
            "meta_release_string")
                ORIGINAL_VBMETA_RELEASE_STRING="$KEY"
                ;;
            "prop")
                APPEND_UNIQUE "ORIGINAL_VBMETA_PROPS" "$KEY=$VALUE"
                ;;
            "hash")
                APPEND_UNIQUE "ORIGINAL_HASH_PARTITIONS" "$KEY"
                ;;
            "hashtree")
                APPEND_UNIQUE "ORIGINAL_HASHTREE_PARTITIONS" "$KEY"
                ;;
            "chain")
                APPEND_UNIQUE "ORIGINAL_CHAIN_PARTITIONS" "$KEY=$VALUE"
                ;;
            "kernel_cmdline")
                printf '%s\t%s\n' "$KEY" "$VALUE" >> "$ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE"
                ORIGINAL_VBMETA_KERNEL_CMDLINE_COUNT="$((ORIGINAL_VBMETA_KERNEL_CMDLINE_COUNT + 1))"
                ;;
        esac
    done < <(
        "$AVB_PYTHON_BIN" - "$AVBTOOL_PATH" "$ORIGINAL_VBMETA" <<'PY'
import base64
import importlib.util
import sys

avbtool_path, image_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

avb = module.Avb()
image = module.ImageHandler(image_path, read_only=True)
_, header, descriptors, _ = avb._parse_image(image)
alg_name, _ = module.lookup_algorithm_by_type(header.algorithm_type)

print(f'meta_algorithm\t{alg_name}')
print(f'meta_rollback_index\t{header.rollback_index}')
print(f'meta_rollback_index_location\t{header.rollback_index_location}')
print(f'meta_release_string\t{header.release_string}')

for desc in descriptors:
    if isinstance(desc, module.AvbPropertyDescriptor):
        value = desc.value.decode('utf-8', errors='replace')
        print(f'prop\t{desc.key}\t{value}')
    elif isinstance(desc, module.AvbHashtreeDescriptor):
        print(f'hashtree\t{desc.partition_name}')
    elif isinstance(desc, module.AvbHashDescriptor):
        print(f'hash\t{desc.partition_name}')
    elif isinstance(desc, module.AvbChainPartitionDescriptor):
        print(f'chain\t{desc.partition_name}\t{desc.rollback_index_location}')
    elif isinstance(desc, module.AvbKernelCmdlineDescriptor):
        value = base64.b64encode(desc.kernel_cmdline.encode('utf-8')).decode('ascii')
        print(f'kernel_cmdline\t{desc.flags}\t{value}')
PY
    )

    TRAILER_INFO="$(
        "$AVB_PYTHON_BIN" - "$AVBTOOL_PATH" "$ORIGINAL_VBMETA" <<'PY'
import importlib.util
import os
import sys

avbtool_path, image_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

avb = module.Avb()
image = module.ImageHandler(image_path, read_only=True)
_, header, _, _ = avb._parse_image(image)
expected_size = 256 + header.authentication_data_block_size + header.auxiliary_data_block_size
actual_size = os.path.getsize(image_path)

if actual_size <= expected_size:
    raise SystemExit(0)

with open(image_path, 'rb') as fh:
    fh.seek(expected_size)
    trailer = fh.read()

marker = ''
for candidate in (b'SignerVer03', b'SignerVer02'):
    if candidate in trailer:
        marker = candidate.decode('ascii')
        break

if marker:
    print(f'{expected_size}\t{actual_size - expected_size}\t{marker}')
PY
    )"

    if [ -n "$TRAILER_INFO" ]; then
        TRAILER_OFFSET="$(cut -f 1 <<< "$TRAILER_INFO")"
        TRAILER_SIZE="$(cut -f 2 <<< "$TRAILER_INFO")"
        TRAILER_MARKER="$(cut -f 3 <<< "$TRAILER_INFO")"
        ORIGINAL_VBMETA_TRAILER_PATH="$STAGING_DIR/original_vbmeta_trailer.bin"
        dd if="$ORIGINAL_VBMETA" of="$ORIGINAL_VBMETA_TRAILER_PATH" bs=1 skip="$TRAILER_OFFSET" count="$TRAILER_SIZE" status=none || exit 1
        ORIGINAL_VBMETA_TRAILER_SIZE="$TRAILER_SIZE"
        ORIGINAL_VBMETA_TRAILER_MARKER="$TRAILER_MARKER"
        LOG "- Preserving original vbmeta trailer: marker=$ORIGINAL_VBMETA_TRAILER_MARKER size=$(FORMAT_SIZE "$ORIGINAL_VBMETA_TRAILER_SIZE")"
    fi

    LOG_PARTITION_SET "Original vbmeta props" "$ORIGINAL_VBMETA_PROPS"
    [ -n "$ORIGINAL_VBMETA_ALGORITHM" ] && AVB_DEBUG_LOG "Original vbmeta algorithm: $ORIGINAL_VBMETA_ALGORITHM"
    LOG_PARTITION_SET "Original vbmeta hash partitions" "$ORIGINAL_HASH_PARTITIONS"
    LOG_PARTITION_SET "Original vbmeta hashtree partitions" "$ORIGINAL_HASHTREE_PARTITIONS"
    LOG_PARTITION_SET "Original vbmeta chain partitions" "$ORIGINAL_CHAIN_PARTITIONS"
    AVB_DEBUG_LOG "Original vbmeta kernel cmdline descriptors: $ORIGINAL_VBMETA_KERNEL_CMDLINE_COUNT"
}

PARSE_ORIGINAL_VBMETA_SAMSUNG_LAYOUT()
{
    local ORIGINAL_VBMETA_SAMSUNG
    local KIND
    local KEY
    local VALUE
    local TRAILER_INFO=""
    local TRAILER_OFFSET=""
    local TRAILER_SIZE=""
    local TRAILER_MARKER=""
    local ORIGINAL_PARTITIONS=""

    $TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT || return 0

    ORIGINAL_VBMETA_SAMSUNG="$(GET_ORIGINAL_VBMETA_SAMSUNG_PATH)"
    [ -f "$ORIGINAL_VBMETA_SAMSUNG" ] || return 0
    [ -n "$AVB_PYTHON_BIN" ] || return 0
    [ -f "$AVBTOOL_PATH" ] || return 0

    DUMP_AVB_INFO_IMAGE "$ORIGINAL_VBMETA_SAMSUNG" "original vbmeta_samsung"

    while IFS=$'\t' read -r KIND KEY VALUE; do
        case "$KIND" in
            "meta_algorithm")
                ORIGINAL_VBMETA_SAMSUNG_ALGORITHM="$KEY"
                ;;
            "meta_rollback_index")
                ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX="$KEY"
                ;;
            "meta_rollback_index_location")
                ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX_LOCATION="$KEY"
                ;;
            "meta_release_string")
                ORIGINAL_VBMETA_SAMSUNG_RELEASE_STRING="$KEY"
                ;;
            "prop")
                APPEND_UNIQUE "ORIGINAL_VBMETA_SAMSUNG_PROPS" "$KEY=$VALUE"
                ;;
            "hash" | "hashtree" | "chain")
                APPEND_UNIQUE "ORIGINAL_PARTITIONS" "$KEY"
                ;;
        esac
    done < <(
        "$AVB_PYTHON_BIN" - "$AVBTOOL_PATH" "$ORIGINAL_VBMETA_SAMSUNG" <<'PY'
import importlib.util
import sys

avbtool_path, image_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

avb = module.Avb()
image = module.ImageHandler(image_path, read_only=True)
_, header, descriptors, _ = avb._parse_image(image)
alg_name, _ = module.lookup_algorithm_by_type(header.algorithm_type)

print(f'meta_algorithm\t{alg_name}')
print(f'meta_rollback_index\t{header.rollback_index}')
print(f'meta_rollback_index_location\t{header.rollback_index_location}')
print(f'meta_release_string\t{header.release_string}')

for desc in descriptors:
    if isinstance(desc, module.AvbPropertyDescriptor):
        value = desc.value.decode('utf-8', errors='replace')
        print(f'prop\t{desc.key}\t{value}')
    elif isinstance(desc, module.AvbHashtreeDescriptor):
        print(f'hashtree\t{desc.partition_name}')
    elif isinstance(desc, module.AvbHashDescriptor):
        print(f'hash\t{desc.partition_name}')
    elif isinstance(desc, module.AvbChainPartitionDescriptor):
        print(f'chain\t{desc.partition_name}\t{desc.rollback_index_location}')
PY
    )

    TRAILER_INFO="$(
        "$AVB_PYTHON_BIN" - "$AVBTOOL_PATH" "$ORIGINAL_VBMETA_SAMSUNG" <<'PY'
import importlib.util
import os
import sys

avbtool_path, image_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

avb = module.Avb()
image = module.ImageHandler(image_path, read_only=True)
_, header, _, _ = avb._parse_image(image)
expected_size = 256 + header.authentication_data_block_size + header.auxiliary_data_block_size
actual_size = os.path.getsize(image_path)

if actual_size <= expected_size:
    raise SystemExit(0)

with open(image_path, 'rb') as fh:
    fh.seek(expected_size)
    trailer = fh.read()

marker = ''
for candidate in (b'SignerVer03', b'SignerVer02'):
    if candidate in trailer:
        marker = candidate.decode('ascii')
        break

if marker:
    print(f'{expected_size}\t{actual_size - expected_size}\t{marker}')
PY
    )"

    if [ -n "$TRAILER_INFO" ]; then
        TRAILER_OFFSET="$(cut -f 1 <<< "$TRAILER_INFO")"
        TRAILER_SIZE="$(cut -f 2 <<< "$TRAILER_INFO")"
        TRAILER_MARKER="$(cut -f 3 <<< "$TRAILER_INFO")"
        ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH="$STAGING_DIR/original_vbmeta_samsung_trailer.bin"
        dd if="$ORIGINAL_VBMETA_SAMSUNG" of="$ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH" bs=1 skip="$TRAILER_OFFSET" count="$TRAILER_SIZE" status=none || exit 1
        ORIGINAL_VBMETA_SAMSUNG_TRAILER_SIZE="$TRAILER_SIZE"
        ORIGINAL_VBMETA_SAMSUNG_TRAILER_MARKER="$TRAILER_MARKER"
        LOG "- Preserving original vbmeta_samsung trailer: marker=$ORIGINAL_VBMETA_SAMSUNG_TRAILER_MARKER size=$(FORMAT_SIZE "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_SIZE")"
    fi

    LOG_PARTITION_SET "Original vbmeta_samsung props" "$ORIGINAL_VBMETA_SAMSUNG_PROPS"
    LOG_PARTITION_SET "Original vbmeta_samsung partitions" "$ORIGINAL_PARTITIONS"
    [ -n "$ORIGINAL_VBMETA_SAMSUNG_ALGORITHM" ] && AVB_DEBUG_LOG "Original vbmeta_samsung algorithm: $ORIGINAL_VBMETA_SAMSUNG_ALGORITHM"
}

ADOPT_ORIGINAL_VBMETA_DEFAULTS()
{
    if [ -n "$ORIGINAL_VBMETA_ALGORITHM" ] && [ "$TARGET_AVB_KEY_PATH" = "$DEFAULT_CUSTOM_AVB_KEY_PATH" ] && \
            [ "$TARGET_AVB_ALGORITHM" != "$ORIGINAL_VBMETA_ALGORITHM" ]; then
        LOG "- Adopting original vbmeta signing algorithm: $ORIGINAL_VBMETA_ALGORITHM"
        TARGET_AVB_ALGORITHM="$ORIGINAL_VBMETA_ALGORITHM"
    fi

    if [ "$TARGET_AVB_ROLLBACK_INDEX" = "0" ] && [ -n "$ORIGINAL_VBMETA_ROLLBACK_INDEX" ]; then
        TARGET_AVB_ROLLBACK_INDEX="$ORIGINAL_VBMETA_ROLLBACK_INDEX"
    fi
    if [ "$TARGET_AVB_ROLLBACK_INDEX_LOCATION" = "0" ] && [ -n "$ORIGINAL_VBMETA_ROLLBACK_INDEX_LOCATION" ]; then
        TARGET_AVB_ROLLBACK_INDEX_LOCATION="$ORIGINAL_VBMETA_ROLLBACK_INDEX_LOCATION"
    fi
}

MERGE_LAYOUT()
{
    local ENTRY
    local PARTITION
    local LOCATION

    HASH_PARTITIONS="$TARGET_AVB_HASH_PARTITIONS"
    HASHTREE_PARTITIONS="$TARGET_AVB_HASHTREE_PARTITIONS"
    CHAIN_PARTITIONS="$TARGET_AVB_CHAIN_PARTITIONS"

    if [ -z "$HASH_PARTITIONS$HASHTREE_PARTITIONS$CHAIN_PARTITIONS" ] && \
            [ -z "$ORIGINAL_HASH_PARTITIONS$ORIGINAL_HASHTREE_PARTITIONS$ORIGINAL_CHAIN_PARTITIONS" ]; then
        LOGW "Original vbmeta layout is unavailable; falling back to built-in AVB partition defaults"
        HASH_PARTITIONS="$(GET_FALLBACK_HASH_PARTITIONS)"
        HASHTREE_PARTITIONS="$(GET_FALLBACK_HASHTREE_PARTITIONS)"
        CHAIN_PARTITIONS="$(GET_FALLBACK_CHAIN_PARTITIONS)"
    fi

    for PARTITION in $EXCLUDED_VBMETA_PARTITIONS; do
        if LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS"; then
            LOGW "Removing $PARTITION from TARGET_AVB_HASH_PARTITIONS; verification for this partition is disabled"
            REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
        fi
        if LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
            LOGW "Removing $PARTITION from TARGET_AVB_HASHTREE_PARTITIONS; verification for this partition is disabled"
            REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"
        fi
        LOCATION="$(GET_KV_VALUE "$PARTITION" "$CHAIN_PARTITIONS")"
        if [ -n "$LOCATION" ]; then
            LOGW "Removing $PARTITION from TARGET_AVB_CHAIN_PARTITIONS; verification for this partition is disabled"
            REMOVE_KV_ITEM "CHAIN_PARTITIONS" "$PARTITION"
        fi
    done

    for ENTRY in $ORIGINAL_HASH_PARTITIONS; do
        if IS_EXCLUDED_AVB_PARTITION "$ENTRY"; then
            LOG "- Ignoring original vbmeta hash descriptor for $ENTRY; verification for this partition is disabled"
            continue
        fi
        SET_PARTITION_SIGN_KIND "$ENTRY" "hash"
    done

    for ENTRY in $ORIGINAL_HASHTREE_PARTITIONS; do
        if IS_EXCLUDED_AVB_PARTITION "$ENTRY"; then
            LOG "- Ignoring original vbmeta hashtree descriptor for $ENTRY; verification for this partition is disabled"
            continue
        fi
        SET_PARTITION_SIGN_KIND "$ENTRY" "hashtree"
    done

    for ENTRY in $ORIGINAL_CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        if IS_EXCLUDED_AVB_PARTITION "$PARTITION"; then
            LOG "- Ignoring original vbmeta chain descriptor for $PARTITION; verification for this partition is disabled"
            continue
        fi
        APPEND_UNIQUE "CHAIN_PARTITIONS" "$ENTRY"
    done

    for ENTRY in $TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        if IS_EXCLUDED_AVB_PARTITION "$PARTITION"; then
            LOG "- Ignoring configured firmware descriptor for $PARTITION; verification for this partition is disabled"
            continue
        fi
        SET_PARTITION_SIGN_KIND "$PARTITION" "hash"
    done

    LOG_PARTITION_SET "Merged AVB hash partitions" "$HASH_PARTITIONS"
    LOG_PARTITION_SET "Merged AVB hashtree partitions" "$HASHTREE_PARTITIONS"
    LOG_PARTITION_SET "Merged AVB chain partitions" "$CHAIN_PARTITIONS"
    LOG_PARTITION_SET "Include vbmeta partition descriptors" "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS"
    LOG_PARTITION_SET "Configured firmware descriptor overrides" "$TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS"
}

IS_PRESENT_IN_ORIGINAL_VBMETA()
{
    local PARTITION="$1"

    if [ -z "$ORIGINAL_HASH_PARTITIONS$ORIGINAL_HASHTREE_PARTITIONS$ORIGINAL_CHAIN_PARTITIONS" ]; then
        return 0
    fi

    LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASH_PARTITIONS" && return 0
    LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASHTREE_PARTITIONS" && return 0
    [ -n "$(GET_KV_VALUE "$PARTITION" "$ORIGINAL_CHAIN_PARTITIONS")" ]
}

IS_EXPLICITLY_CONFIGURED_VBMETA_PARTITION()
{
    local PARTITION="$1"
    local ENTRY

    LIST_HAS_ITEM "$PARTITION" "$TARGET_AVB_HASH_PARTITIONS" && return 0
    LIST_HAS_ITEM "$PARTITION" "$TARGET_AVB_HASHTREE_PARTITIONS" && return 0
    [ -n "$(GET_KV_VALUE "$PARTITION" "$TARGET_AVB_CHAIN_PARTITIONS")" ] && return 0

    for ENTRY in $TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS; do
        [ "${ENTRY%%=*}" = "$PARTITION" ] && return 0
    done

    return 1
}

SHOULD_INCLUDE_IN_TOPLEVEL_VBMETA()
{
    local PARTITION="$1"

    IS_EXPLICITLY_CONFIGURED_VBMETA_PARTITION "$PARTITION" && return 0
    IS_PRESENT_IN_ORIGINAL_VBMETA "$PARTITION"
}

ASSERT_REQUIRED_RE_SIGN_COVERAGE()
{
    local PARTITION

    for PARTITION in $REQUIRED_RE_SIGN_PARTITIONS; do
        [ -f "$TMP_IMG_DIR/$PARTITION.img" ] || continue

        if LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS" || \
                LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS" || \
                [ -n "$(GET_CHAIN_LOCATION "$PARTITION")" ]; then
            continue
        fi

        LOGE "AVB-relevant image $PARTITION.img is present but not configured for custom AVB re-signing. Add it to TARGET_AVB_HASH_PARTITIONS, TARGET_AVB_HASHTREE_PARTITIONS or TARGET_AVB_CHAIN_PARTITIONS."
        exit 1
    done
}

SETUP_AVBTOOL()
{
    if [ ! -f "$UPSTREAM_AVBTOOL_PATH" ]; then
        LOGE "Official AVB reference not found: $UPSTREAM_AVBTOOL_PATH"
        exit 1
    fi

    if [ "$TARGET_AVBTOOL_PATH" != "none" ] && [ "$TARGET_AVBTOOL_PATH" != "$UPSTREAM_AVBTOOL_PATH" ]; then
        LOGW "Ignoring TARGET_AVBTOOL_PATH=$TARGET_AVBTOOL_PATH. Using official AVB reference: $UPSTREAM_AVBTOOL_PATH"
    fi

    TARGET_AVBTOOL_PATH="$UPSTREAM_AVBTOOL_PATH"
    AVBTOOL_PATH="$UPSTREAM_AVBTOOL_PATH"

    if [ "$TARGET_AVBTOOL_PYTHON" != "none" ]; then
        if [[ "$TARGET_AVBTOOL_PYTHON" == */* ]]; then
            [ -x "$TARGET_AVBTOOL_PYTHON" ] || {
                LOGE "Configured AVB python is not executable: $TARGET_AVBTOOL_PYTHON"
                exit 1
            }
        elif ! command -v "$TARGET_AVBTOOL_PYTHON" &> /dev/null; then
            LOGE "Configured AVB python not found in PATH: $TARGET_AVBTOOL_PYTHON"
            exit 1
        fi
        AVB_PYTHON_BIN="$TARGET_AVBTOOL_PYTHON"
    else
        if ! command -v python3 &> /dev/null; then
            LOGE "python3 is required to execute avbtool script: $AVBTOOL_PATH"
            exit 1
        fi
        AVB_PYTHON_BIN="$(command -v python3)"
        TARGET_AVBTOOL_PYTHON="$AVB_PYTHON_BIN"
    fi

    AVBTOOL_CMD=("$AVB_PYTHON_BIN" "$AVBTOOL_PATH")

    AVB_DEBUG_LOG "Using AVB python: $AVB_PYTHON_BIN"
    AVB_DEBUG_LOG "Using AVB tool: $AVBTOOL_PATH"

    if ! "${AVBTOOL_CMD[@]}" version &> /dev/null; then
        LOGE "Configured avbtool could not be executed. Check TARGET_AVBTOOL_PATH/TARGET_AVBTOOL_PYTHON"
        exit 1
    fi
}

GET_AVB_KEY_BITS()
{
    case "$1" in
        SHA256_RSA2048 | SHA512_RSA2048)
            echo "2048"
            ;;
        SHA256_RSA4096 | SHA512_RSA4096)
            echo "4096"
            ;;
        SHA256_RSA8192 | SHA512_RSA8192)
            echo "8192"
            ;;
        *)
            LOGE "Unsupported AVB signing algorithm for auto-generated key: $1"
            exit 1
            ;;
    esac
}

GET_AVB_PUBLIC_KEY_OUTPUT_PATH()
{
    local PRIVATE_KEY_PATH="$1"

    if [[ "$PRIVATE_KEY_PATH" == *_private.pem ]]; then
        echo "${PRIVATE_KEY_PATH%_private.pem}_public.bin"
    elif [[ "$PRIVATE_KEY_PATH" == *.pem ]]; then
        echo "${PRIVATE_KEY_PATH%.pem}_public.bin"
    else
        echo "${PRIVATE_KEY_PATH}.public.bin"
    fi
}

ENSURE_GENERATED_AVB_KEY()
{
    local KEY_PATH="$1"
    local ALGORITHM="$2"
    local KEY_BITS
    local PUBLIC_KEY_PATH

    [ -n "$KEY_PATH" ] && [ "$KEY_PATH" != "none" ] || {
        LOGE "Missing AVB key path for custom AVB flow"
        exit 1
    }
    [ "$ALGORITHM" != "NONE" ] || return 0

    if ! command -v openssl &> /dev/null; then
        LOGE "openssl is required to generate the custom AVB key"
        exit 1
    fi

    KEY_BITS="$(GET_AVB_KEY_BITS "$ALGORITHM")"
    mkdir -p "$(dirname "$KEY_PATH")"

    if [ ! -f "$KEY_PATH" ]; then
        LOG "- Generating custom AVB key ($ALGORITHM) at $KEY_PATH"
        openssl genrsa -out "$KEY_PATH" "$KEY_BITS" || exit 1
        chmod 600 "$KEY_PATH"
    fi

    PUBLIC_KEY_PATH="$(GET_AVB_PUBLIC_KEY_OUTPUT_PATH "$KEY_PATH")"
    if [ ! -f "$PUBLIC_KEY_PATH" ] || [ "$KEY_PATH" -nt "$PUBLIC_KEY_PATH" ]; then
        LOG "- Extracting AVB public key blob to $PUBLIC_KEY_PATH"
        RUN_AVBTOOL extract_public_key --key "$KEY_PATH" --output "$PUBLIC_KEY_PATH" || exit 1
    fi
}

RESOLVE_AVB_KEY_PATH()
{
    local KEY_VALUE="$1"
    local ALGORITHM="$2"

    if [ -n "$KEY_VALUE" ] && [ "$KEY_VALUE" != "none" ]; then
        [ -f "$KEY_VALUE" ] || ENSURE_GENERATED_AVB_KEY "$KEY_VALUE" "$ALGORITHM"
        echo "$KEY_VALUE"
    fi
}

RESOLVE_TOPLEVEL_SIGNING_CONFIG()
{
    local KEY_VALUE="$TARGET_AVB_KEY_PATH"

    VBMETA_SIGN_ALGORITHM="$TARGET_AVB_ALGORITHM"
    VBMETA_SIGN_KEY_PATH="$(RESOLVE_AVB_KEY_PATH "$KEY_VALUE" "$VBMETA_SIGN_ALGORITHM")"
    if [ "$VBMETA_SIGN_ALGORITHM" = "NONE" ]; then
        LOGE "Top-level vbmeta must be signed with a real AVB key"
        exit 1
    fi
    if [ -z "$VBMETA_SIGN_KEY_PATH" ]; then
        LOGE "Missing AVB key for top-level vbmeta (algorithm=$VBMETA_SIGN_ALGORITHM)"
        exit 1
    fi

    AVB_DEBUG_LOG "Top-level vbmeta signing config: algorithm=$VBMETA_SIGN_ALGORITHM key=$VBMETA_SIGN_KEY_PATH rollback_index=$TARGET_AVB_ROLLBACK_INDEX rollback_index_location=$TARGET_AVB_ROLLBACK_INDEX_LOCATION hash_algorithm=$TARGET_AVB_HASH_ALGORITHM"
}

SANITIZE_KEY_LABEL()
{
    printf '%s' "$1" | tr '/:[:space:]' '___' | tr -cd '[:alnum:]_.-'
}

CALCULATE_SHA256()
{
    if command -v shasum &> /dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        python3 - "$1" <<'PY'
import hashlib
import sys

with open(sys.argv[1], 'rb') as fp:
    print(hashlib.sha256(fp.read()).hexdigest())
PY
    fi
}

REGISTER_KEY_USAGE()
{
    local LABEL="$1"
    local KEY_PATH="$2"
    local ALGORITHM="$3"
    local SAFE_LABEL
    local OUTPUT_BLOB
    local DIGEST

    [ -n "$KEY_PATH" ] || return 0

    SAFE_LABEL="$(SANITIZE_KEY_LABEL "$LABEL")"
    LIST_HAS_ITEM "$SAFE_LABEL" "$KEY_EXPORT_LABELS" && return 0

    mkdir -p "$STAGING_DIR/keys"
    OUTPUT_BLOB="$STAGING_DIR/keys/${SAFE_LABEL}.avbpubkey"
    RUN_AVBTOOL extract_public_key --key "$KEY_PATH" --output "$OUTPUT_BLOB" || exit 1
    DIGEST="$(CALCULATE_SHA256 "$OUTPUT_BLOB")"
    APPEND_UNIQUE "KEY_EXPORT_LABELS" "$SAFE_LABEL"

    {
        echo "label=$LABEL"
        echo "algorithm=$ALGORITHM"
        echo "private_key=$KEY_PATH"
        echo "public_key_blob=keys/${SAFE_LABEL}.avbpubkey"
        echo "public_key_sha256=$DIGEST"
        echo
    } >> "$KEY_EXPORT_REPORT"
}

REGISTER_PARTITION_KEY_USAGE_IF_NEEDED()
{
    local PARTITION="$1"
    local CHAIN_LOCATION=""

    [ -n "$PARTITION_SIGN_KEY_PATH" ] || return 0

    CHAIN_LOCATION="$(GET_CHAIN_LOCATION "$PARTITION")"
    if [ -n "$CHAIN_LOCATION" ] || \
            [ "$PARTITION_SIGN_KEY_PATH" != "$VBMETA_SIGN_KEY_PATH" ] || \
            [ "$PARTITION_SIGN_ALGORITHM" != "$VBMETA_SIGN_ALGORITHM" ]; then
        REGISTER_KEY_USAGE "$PARTITION" "$PARTITION_SIGN_KEY_PATH" "$PARTITION_SIGN_ALGORITHM"
    fi
}

ASSERT_IMAGE_VBMETA_FLAGS_ZERO()
{
    local IMAGE="$1"
    local LABEL="$2"
    local FLAGS=""

    FLAGS="$("$AVB_PYTHON_BIN" - "$AVBTOOL_PATH" "$IMAGE" <<'PY'
import importlib.util
import sys

avbtool_path, image_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

avb = module.Avb()
image = module.ImageHandler(image_path, read_only=True)
_, header, _, _ = avb._parse_image(image)
print(header.flags)
PY
)"

    if [ "$FLAGS" != "0" ]; then
        LOGE "$LABEL has insecure vbmeta flags set ($FLAGS). Verification/hashtree disabling is not allowed in the custom AVB flow."
        exit 1
    fi
}

RESOLVE_PARTITION_SIGNING_CONFIG()
{
    local PARTITION="$1"
    local KIND="$2"
    local KEY_VALUE=""
    local CHAIN_LOCATION=""

    PARTITION_SIGN_KEY_PATH=""
    PARTITION_SIGN_ALGORITHM="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ALGORITHM")"
    [ -z "$PARTITION_SIGN_ALGORITHM" ] && PARTITION_SIGN_ALGORITHM="$TARGET_AVB_ALGORITHM"

    PARTITION_SIGN_HASH_ALGORITHM="$(GET_PARTITION_VAR_VALUE "$PARTITION" "HASH_ALGORITHM")"
    [ -z "$PARTITION_SIGN_HASH_ALGORITHM" ] && PARTITION_SIGN_HASH_ALGORITHM="$TARGET_AVB_HASH_ALGORITHM"

    PARTITION_SIGN_ROLLBACK_INDEX="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ROLLBACK_INDEX")"
    [ -z "$PARTITION_SIGN_ROLLBACK_INDEX" ] && PARTITION_SIGN_ROLLBACK_INDEX="0"

    PARTITION_SIGN_ROLLBACK_INDEX_LOCATION="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ROLLBACK_INDEX_LOCATION")"
    CHAIN_LOCATION="$(GET_CHAIN_LOCATION "$PARTITION")"
    # Keep chained partition footers at rollback_index_location=0 by default.
    # The chain descriptor in top-level vbmeta carries the real rollback slot.
    [ -z "$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION" ] && PARTITION_SIGN_ROLLBACK_INDEX_LOCATION="0"
    if [ -n "$CHAIN_LOCATION" ] && [ "$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION" != "0" ]; then
        AVB_DEBUG_LOG "Chained partition $PARTITION uses explicit footer rollback_index_location=$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION; this may raise required libavb version above stock."
    fi

    PARTITION_SIGN_DO_NOT_USE_AB="$(GET_PARTITION_VAR_VALUE "$PARTITION" "DO_NOT_USE_AB")"
    [ -z "$PARTITION_SIGN_DO_NOT_USE_AB" ] && PARTITION_SIGN_DO_NOT_USE_AB="false"

    if [ "$KIND" = "hashtree" ]; then
        PARTITION_SIGN_EXTRA_ARGS="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ADD_HASHTREE_FOOTER_ARGS")"
    else
        PARTITION_SIGN_EXTRA_ARGS="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ADD_HASH_FOOTER_ARGS")"
    fi

    KEY_VALUE="$(GET_PARTITION_VAR_VALUE "$PARTITION" "KEY_PATH")"
    [ -z "$KEY_VALUE" ] && KEY_VALUE="$TARGET_AVB_KEY_PATH"
    PARTITION_SIGN_KEY_PATH="$(RESOLVE_AVB_KEY_PATH "$KEY_VALUE" "$PARTITION_SIGN_ALGORITHM")"

    if [ "$PARTITION_SIGN_ALGORITHM" = "NONE" ]; then
        LOGE "Partition $PARTITION must use a real AVB signing algorithm"
        exit 1
    fi

    if [ -z "$PARTITION_SIGN_KEY_PATH" ]; then
        LOGE "Missing AVB key for partition $PARTITION (algorithm=$PARTITION_SIGN_ALGORITHM)"
        exit 1
    fi

    AVB_DEBUG_LOG "Partition signing config for $PARTITION: kind=$KIND algorithm=$PARTITION_SIGN_ALGORITHM key=$PARTITION_SIGN_KEY_PATH hash_algorithm=$PARTITION_SIGN_HASH_ALGORITHM rollback_index=$PARTITION_SIGN_ROLLBACK_INDEX rollback_index_location=$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION do_not_use_ab=$PARTITION_SIGN_DO_NOT_USE_AB extra_args=${PARTITION_SIGN_EXTRA_ARGS:-<none>}"

}

GET_CHAIN_PUBLIC_KEY_BLOB()
{
    local PARTITION="$1"
    local KEY_PATH="$2"
    local OUTPUT_PATH="$STAGING_DIR/${PARTITION}_public_key.bin"

    [ -f "$OUTPUT_PATH" ] || RUN_AVBTOOL extract_public_key --key "$KEY_PATH" --output "$OUTPUT_PATH" || exit 1
    echo "$OUTPUT_PATH"
}

RUN_AVBTOOL()
{
    AVB_DEBUG_LOG "Running avbtool: $(FORMAT_COMMAND "${AVBTOOL_CMD[@]}" "$@")"
    "${AVBTOOL_CMD[@]}" "$@"
}

DUMP_AVB_INFO_IMAGE()
{
    local IMAGE="$1"
    local LABEL="$2"

    IS_AVB_DEBUG_ENABLED || return 0
    [ -f "$IMAGE" ] || return 0

    AVB_DEBUG_LOG "avbtool info_image for ${LABEL:-$(basename "$IMAGE")}:"
    RUN_AVBTOOL info_image --image "$IMAGE" >&2 || exit 1
}

GET_ABSOLUTE_PATH()
{
    local PATH_VALUE="$1"

    if command -v realpath &> /dev/null; then
        realpath "$PATH_VALUE"
    else
        (
            cd "$(dirname "$PATH_VALUE")" || exit 1
            printf '%s/%s\n' "$(pwd -P)" "$(basename "$PATH_VALUE")"
        )
    fi
}

GET_METADATA_VALUE()
{
    local FILE="$1"
    local KEY="$2"

    [ -f "$FILE" ] || return 0

    sed -n "s/^$KEY=//p" "$FILE" | head -n 1
}

ROUND_UP_TO_4K()
{
    local VALUE="$1"

    echo "$((((VALUE + 4095) / 4096) * 4096))"
}

FORMAT_SIZE()
{
    local VALUE="$1"

    if command -v numfmt &> /dev/null; then
        printf '%s (%s)' "$VALUE" "$(numfmt --to=iec --suffix=B "$VALUE")"
    else
        printf '%s bytes' "$VALUE"
    fi
}

GET_EXPLICIT_PARTITION_SIZE()
{
    local PARTITION="$1"
    local VAR_NAME
    local VALUE

    VAR_NAME="TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE"
    eval "VALUE=\${$VAR_NAME:-}"

    [ -n "$VALUE" ] && [ "$VALUE" != "none" ] && echo "$VALUE"
}

GET_STOCK_IMAGE_PATH()
{
    local PARTITION="$1"
    local CANDIDATE
    local CANDIDATES=()

    case "$PARTITION" in
        "dtb")
            CANDIDATES+=(
                "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/dtb.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/dt.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/dtb.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/dt.img"
            )
            ;;
        "boot" | "dtbo" | "init_boot" | "vendor_boot" | "recovery")
            CANDIDATES+=(
                "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/$PARTITION.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/$PARTITION.img"
            )
            ;;
        *)
            CANDIDATES+=(
                "$FW_DIR/$TARGET_FIRMWARE_PATH/$PARTITION.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/$PARTITION.img"
            )
            ;;
    esac

    for CANDIDATE in "${CANDIDATES[@]}"; do
        [ -f "$CANDIDATE" ] && echo "$CANDIDATE" && return 0
    done
}

GET_METADATA_PARTITION_SIZE()
{
    local PARTITION="$1"
    local VALUE=""

    case "$PARTITION" in
        "boot" | "dtbo" | "init_boot" | "vendor_boot" | "recovery")
            VALUE="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/$PARTITION.img_metadata.txt" "partition_size")"
            ;;
        *)
            VALUE="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/$PARTITION.img_metadata.txt" "partition_size")"
            [ -z "$VALUE" ] && VALUE="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/os_partitions_metadata.txt" "${PARTITION}_size")"
            ;;
    esac

    [ -n "$VALUE" ] && echo "$VALUE"
}

GET_STOCK_IMAGE_PARTITION_SIZE()
{
    local PARTITION="$1"
    local IMAGE

    IMAGE="$(GET_STOCK_IMAGE_PATH "$PARTITION")"
    [ -f "$IMAGE" ] || return 0

    GET_IMAGE_SIZE "$IMAGE"
}

GET_EXISTING_AVB_IMAGE_PARTITION_SIZE()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"

    [ -f "$IMAGE" ] || return 0
    RUN_AVBTOOL info_image --image "$IMAGE" &> /dev/null || return 0

    GET_IMAGE_SIZE "$IMAGE"
}

ESTIMATE_PARTITION_SIZE_FROM_IMAGE_PATH()
{
    local IMAGE="$1"
    local KIND="$2"
    local IMAGE_SIZE
    local EXTRA_SIZE

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"

    if [ "$KIND" = "hashtree" ]; then
        EXTRA_SIZE="$((IMAGE_SIZE / 64))"
        [ "$EXTRA_SIZE" -lt $((16 * 1024 * 1024)) ] && EXTRA_SIZE=$((16 * 1024 * 1024))
    else
        EXTRA_SIZE=$((4 * 1024 * 1024))
    fi

    echo "$(ROUND_UP_TO_4K "$((IMAGE_SIZE + EXTRA_SIZE))")"
}

IS_DYNAMIC_AVB_PARTITION()
{
    local PARTITION="$1"

    [ "${TARGET_SUPER_PARTITION_SIZE:-0}" -ne 0 ] || return 1

    case "$PARTITION" in
        "system" | "vendor" | "product" | "system_ext" | "odm" | "vendor_dlkm" | "odm_dlkm" | "system_dlkm")
            return 0
            ;;
    esac

    return 1
}

ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local KIND="$2"

    [ -f "$IMAGE" ] || return 0

    ESTIMATE_PARTITION_SIZE_FROM_IMAGE_PATH "$IMAGE" "$KIND"
}

CALCULATE_AVB_MAX_IMAGE_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local CMD=()
    local OUTPUT=""
    local STDERR_FILE="$STAGING_DIR/calc_max_${PARTITION}_${KIND}.stderr"
    local CMD_STRING=""
    local ARG

    BUILD_SIGN_IMAGE_CMD CMD "" "$PARTITION" "$KIND" "$PARTITION_SIZE" "calc"
    AVB_DEBUG_LOG "Calculating AVB max image size for $PARTITION ($KIND): $(FORMAT_COMMAND "${AVBTOOL_CMD[@]}" "${CMD[@]}")"

    rm -f "$STDERR_FILE"
    OUTPUT="$(RUN_AVBTOOL "${CMD[@]}" 2> "$STDERR_FILE" | tail -n 1 | tr -d '[:space:]')" || true

    if ! [[ "$OUTPUT" =~ ^[0-9]+$ ]]; then
        for ARG in "${AVBTOOL_CMD[@]}" "${CMD[@]}"; do
            if [ -n "$CMD_STRING" ]; then
                CMD_STRING+=" "
            fi
            CMD_STRING+="$(printf '%q' "$ARG")"
        done

        if [ -s "$STDERR_FILE" ]; then
            LOGE "Official AVB calc_max_image_size failed for $PARTITION ($KIND): $(tr '\n' ' ' < "$STDERR_FILE" | sed 's/[[:space:]]\\+/ /g')"
        else
            LOGE "Official AVB calc_max_image_size returned no numeric output for $PARTITION ($KIND)"
        fi
        LOGE "Failing AVB command: $CMD_STRING"
        return 1
    fi

    AVB_DEBUG_LOG "Calculated AVB max image size for $PARTITION ($KIND): $OUTPUT"

    echo "$OUTPUT"
}

CALCULATE_MIN_AVB_PARTITION_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local IMAGE_SIZE
    local LOWER_BOUND
    local UPPER_BOUND
    local MID
    local MAX_IMAGE_SIZE

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"
    LOWER_BOUND="$IMAGE_SIZE"
    UPPER_BOUND="$(ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE "$PARTITION" "$KIND")"
    [ -n "$UPPER_BOUND" ] || return 1
    UPPER_BOUND="$(ROUND_UP_TO_4K "$UPPER_BOUND")"
    [ "$UPPER_BOUND" -lt "$LOWER_BOUND" ] && UPPER_BOUND="$LOWER_BOUND"

    while true; do
        MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$UPPER_BOUND")" || return 1
        [ "$MAX_IMAGE_SIZE" -ge "$IMAGE_SIZE" ] && break

        UPPER_BOUND="$(ROUND_UP_TO_4K "$((UPPER_BOUND * 2))")"
        [ "$UPPER_BOUND" -gt $((128 * 1024 * 1024 * 1024)) ] && return 1
    done

    while [ "$LOWER_BOUND" -lt "$UPPER_BOUND" ]; do
        MID="$((((LOWER_BOUND + UPPER_BOUND) / 2) / 4096 * 4096))"
        # Bounds are 4 KiB-aligned. If the midpoint rounds back to the current
        # lower bound, there is no aligned candidate left between the bounds.
        [ "$MID" -le "$LOWER_BOUND" ] && break

        MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$MID")" || return 1
        if [ "$MAX_IMAGE_SIZE" -ge "$IMAGE_SIZE" ]; then
            UPPER_BOUND="$MID"
        else
            LOWER_BOUND="$(ROUND_UP_TO_4K "$((MID + 1))")"
        fi
    done

    echo "$UPPER_BOUND"
}

CAN_SIGN_IMAGE_WITH_PARTITION_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local IMAGE_SIZE
    local MAX_IMAGE_SIZE

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"

    MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE")" || return 1
    [ "$MAX_IMAGE_SIZE" -ge "$IMAGE_SIZE" ]
}

RESOLVE_SIGN_PARTITION_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local VALUE
    local LIMIT=0
    local ATTEMPTS=0

    if CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE"; then
        echo "$PARTITION_SIZE"
        return 0
    fi

    if IS_DYNAMIC_AVB_PARTITION "$PARTITION"; then
        LIMIT="${TARGET_SUPER_GROUP_SIZE:-0}"
        [ "$LIMIT" -le 0 ] && LIMIT="${TARGET_SUPER_PARTITION_SIZE:-0}"
        VALUE="$PARTITION_SIZE"

        while [ "$ATTEMPTS" -lt 16 ]; do
            ATTEMPTS="$((ATTEMPTS + 1))"
            VALUE="$(ROUND_UP_TO_4K "$((VALUE + (64 * 1024 * 1024)))")"

            if [ "$LIMIT" -gt 0 ] && [ "$VALUE" -gt "$LIMIT" ]; then
                VALUE="$LIMIT"
            fi

            if CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "$KIND" "$VALUE"; then
                LOGW "Increasing AVB partition size for dynamic partition $PARTITION: $PARTITION_SIZE -> $VALUE" >&2
                echo "$VALUE"
                return 0
            fi

            if [ "$LIMIT" -gt 0 ] && [ "$VALUE" -ge "$LIMIT" ]; then
                break
            fi
        done

        VALUE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND")"
        if [ -n "$VALUE" ] && [ "$VALUE" -gt "$PARTITION_SIZE" ]; then
            LOGW "Increasing AVB partition size for dynamic partition $PARTITION: $PARTITION_SIZE -> $VALUE" >&2
            echo "$VALUE"
            return 0
        fi
    fi

    VALUE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND")"
    if [ -n "$VALUE" ] && [ "$VALUE" -gt "$PARTITION_SIZE" ]; then
        LOGW "Increasing AVB partition size for $PARTITION: $PARTITION_SIZE -> $VALUE" >&2
        echo "$VALUE"
        return 0
    fi

    echo "$PARTITION_SIZE"
}

GET_PARTITION_SIZE_INFO()
{
    local PARTITION="$1"
    local VALUE=""
    local KIND

    VALUE="$(GET_EXPLICIT_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE|explicit" && return 0

    VALUE="$(GET_METADATA_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE|metadata" && return 0

    VALUE="$(GET_EXISTING_AVB_IMAGE_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE|existing_avb_image_size" && return 0

    VALUE="$(GET_STOCK_IMAGE_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE|stock_image_size" && return 0

    KIND="$(GET_SIGN_KIND "$PARTITION")"
    if IS_DYNAMIC_AVB_PARTITION "$PARTITION"; then
        LOG "- Resolving dynamic AVB partition size for $PARTITION from the built image" >&2

        VALUE="$(ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE "$PARTITION" "$KIND")"
        if [ -n "$VALUE" ]; then
            LOGW "Estimated AVB partition size for dynamic partition $PARTITION: $VALUE" >&2
            echo "$VALUE|dynamic_estimate"
            return 0
        fi

        VALUE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND")"
        if [ -n "$VALUE" ]; then
            LOGW "Calculated AVB partition size for dynamic partition $PARTITION from the built image: $VALUE" >&2
            echo "$VALUE|dynamic_calculated"
            return 0
        fi
    fi

    VALUE="$(ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE "$PARTITION" "$KIND")"
    if [ -n "$VALUE" ]; then
        LOGW "Estimated AVB partition size for $PARTITION from the built image: $VALUE" >&2
        echo "$VALUE|built_image_estimate"
        return 0
    fi

    VALUE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND")"
    if [ -n "$VALUE" ]; then
        LOGW "Calculated AVB partition size for $PARTITION from the built image: $VALUE" >&2
        echo "$VALUE|built_image_calculated"
        return 0
    fi

    return 1
}

GET_PARTITION_SIZE()
{
    local PARTITION="$1"
    local INFO=""

    INFO="$(GET_PARTITION_SIZE_INFO "$PARTITION")" || {
        LOGE "Unable to determine a fixed partition size for $PARTITION. Re-extract firmware metadata or set TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE"
        return 1
    }

    echo "${INFO%%|*}"
}

GET_SIGN_KIND()
{
    local PARTITION="$1"

    if LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
        echo "hashtree"
    elif LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS"; then
        echo "hash"
    else
        echo "hash"
    fi
}

BUILD_SIGN_IMAGE_CMD()
{
    local ARRAY_NAME="$1"
    local IMAGE="$2"
    local PARTITION="$3"
    local KIND="$4"
    local PARTITION_SIZE="$5"
    local MODE="$6"
    local BUILT_CMD=()

    RESOLVE_PARTITION_SIGNING_CONFIG "$PARTITION" "$KIND"

    if [ "$KIND" = "hashtree" ]; then
        BUILT_CMD=(add_hashtree_footer)
    else
        BUILT_CMD=(add_hash_footer)
    fi

    if [ "$MODE" = "calc" ]; then
        BUILT_CMD+=(--calc_max_image_size)
    else
        BUILT_CMD+=(--image "$IMAGE")
    fi

    BUILT_CMD+=(
        --partition_name "$PARTITION"
        --partition_size "$PARTITION_SIZE"
        --hash_algorithm "$PARTITION_SIGN_HASH_ALGORITHM"
        --rollback_index "$PARTITION_SIGN_ROLLBACK_INDEX"
        --rollback_index_location "$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION"
    )

    if [ "$PARTITION_SIGN_ALGORITHM" = "NONE" ]; then
        BUILT_CMD+=(--algorithm NONE)
    else
        BUILT_CMD+=(--algorithm "$PARTITION_SIGN_ALGORITHM" --key "$PARTITION_SIGN_KEY_PATH")
    fi

    [ "$PARTITION_SIGN_DO_NOT_USE_AB" = "true" ] && BUILT_CMD+=(--do_not_use_ab)
    APPEND_ARGS_FROM_STRING BUILT_CMD "$PARTITION_SIGN_EXTRA_ARGS"

    eval "$ARRAY_NAME=(\"\${BUILT_CMD[@]}\")"
}

ERASE_FOOTER_IF_PRESENT()
{
    local IMAGE="$1"

    if RUN_AVBTOOL info_image --image "$IMAGE" &> /dev/null; then
        LOG "- Removing existing AVB footer from $(basename "$IMAGE") before re-signing"
        RUN_AVBTOOL erase_footer --image "$IMAGE" || exit 1
    fi
}

REMOVE_SAMSUNG_SIGNATURES_IF_PRESENT()
{
    local IMAGE="$1"
    local BEFORE_SIZE
    local AFTER_SIZE
    local TRIM_SIZE=0
    local CHANGED=false

    BEFORE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || exit 1

    if head -c 4096 "$IMAGE" | grep -a -q "SignerVer"; then
        LOG "- Removing Samsung header signature from $(basename "$IMAGE") before custom AVB re-signing"
        dd if="/dev/zero" of="$IMAGE" bs=256 seek=0 count=1 conv=notrunc &> /dev/null
        dd if="/dev/zero" of="$IMAGE" bs=256 seek=3 count=1 conv=notrunc &> /dev/null
        CHANGED=true
    fi

    if tail -c 4096 "$IMAGE" | grep -a -q "SignerVer03"; then
        TRIM_SIZE=784
    elif tail -c 4096 "$IMAGE" | grep -a -q "SignerVer02"; then
        TRIM_SIZE=512
    fi

    if [ "$TRIM_SIZE" -gt 0 ]; then
        LOG "- Removing Samsung footer signature from $(basename "$IMAGE") before custom AVB re-signing"
        truncate -s "-$TRIM_SIZE" "$IMAGE" || exit 1
        CHANGED=true
    fi

    if $CHANGED; then
        AFTER_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || exit 1
        LOG "- Samsung signature cleanup result for $(basename "$IMAGE"): $(FORMAT_SIZE "$BEFORE_SIZE") -> $(FORMAT_SIZE "$AFTER_SIZE")"
    fi
}

PREPARE_IMAGE_FOR_CUSTOM_AVB_SIGNING()
{
    local IMAGE="$1"

    ERASE_FOOTER_IF_PRESENT "$IMAGE"
    if [ "$TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES" = "true" ]; then
        AVB_DEBUG_LOG "Preserving Samsung signature areas in $(basename "$IMAGE") before custom AVB signing"
    else
        REMOVE_SAMSUNG_SIGNATURES_IF_PRESENT "$IMAGE"
    fi
    ERASE_FOOTER_IF_PRESENT "$IMAGE"
}

PREPARE_IMAGE_FOR_DESCRIPTOR_AVB_SIGNING()
{
    local IMAGE="$1"

    ERASE_FOOTER_IF_PRESENT "$IMAGE"
}

GET_FIRMWARE_DESCRIPTOR_FILENAME()
{
    local PARTITION="$1"
    local VALUE=""

    VALUE="$(GET_KV_VALUE "$PARTITION" "$TARGET_AVB_FIRMWARE_IMAGE_MAP")"
    [ -n "$VALUE" ] && echo "$VALUE"
}

GET_FIRMWARE_DESCRIPTOR_FILENAME_CANDIDATES()
{
    local PARTITION="$1"
    local FILE_NAME=""
    local CANDIDATES=""

    FILE_NAME="$(GET_FIRMWARE_DESCRIPTOR_FILENAME "$PARTITION")"
    [ -n "$FILE_NAME" ] && APPEND_UNIQUE "CANDIDATES" "$FILE_NAME"
    APPEND_UNIQUE "CANDIDATES" "$PARTITION.img"
    APPEND_UNIQUE "CANDIDATES" "$PARTITION.bin"
    APPEND_UNIQUE "CANDIDATES" "$PARTITION"

    echo "$CANDIDATES"
}

LIST_TARGET_FIRMWARE_TARS()
{
    local FW_ODIN_DIR="$ODIN_DIR/${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}"

    [ -d "$FW_ODIN_DIR" ] || return 1

    find "$FW_ODIN_DIR" -maxdepth 1 -type f \( -name "*.md5" -o -name "*.tar" \) | sort -r
}

EXTRACT_FILE_FROM_TAR_TO_PATH()
{
    local TAR_FILE="$1"
    local ENTRY_NAME="$2"
    local OUTPUT_PATH="$3"
    local OUTPUT_DIR

    OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT_PATH" "$OUTPUT_PATH.lz4"

    if FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME"; then
        EVAL "tar xf \"$TAR_FILE\" -C \"$OUTPUT_DIR\" \"$ENTRY_NAME\"" || exit 1
    elif FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME.lz4"; then
        EVAL "tar xf \"$TAR_FILE\" -C \"$OUTPUT_DIR\" \"$ENTRY_NAME.lz4\"" || exit 1
        EVAL "lz4 -d --rm \"$OUTPUT_DIR/$ENTRY_NAME.lz4\" \"$OUTPUT_PATH\"" || exit 1
    else
        LOGE "File $ENTRY_NAME(.lz4) not found in $TAR_FILE"
        exit 1
    fi

    [ -f "$OUTPUT_PATH" ] || {
        LOGE "Failed to extract $ENTRY_NAME from $TAR_FILE"
        exit 1
    }
}

GET_FIRMWARE_DESCRIPTOR_SOURCE_PATH()
{
    local PARTITION="$1"
    local FILE_NAME=""
    local SOURCE_PATH=""
    local CANDIDATES=""
    local FW_ODIN_DIR="$ODIN_DIR/${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}"
    local EXTRACTED_CANDIDATE=""
    local TAR_FILE=""

    CANDIDATES="$(GET_FIRMWARE_DESCRIPTOR_FILENAME_CANDIDATES "$PARTITION")"
    [ -n "$CANDIDATES" ] || return 1

    for FILE_NAME in $CANDIDATES; do
        if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_BOOTLOADER && \
                [ -f "$TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR/$FILE_NAME" ]; then
            LOG "- Using signed bootloader component $FILE_NAME for $PARTITION AVB descriptor" >&2
            echo "$TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR/$FILE_NAME"
            return 0
        fi

        for EXTRACTED_CANDIDATE in \
            "$FW_DIR/$TARGET_FIRMWARE_PATH/$FILE_NAME" \
            "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/$FILE_NAME" \
            "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/$FILE_NAME"; do
            if [ -f "$EXTRACTED_CANDIDATE" ]; then
                echo "$EXTRACTED_CANDIDATE"
                return 0
            fi
        done

        SOURCE_PATH="$STAGING_DIR/fw_odin/$FILE_NAME"
        if [ -f "$SOURCE_PATH" ]; then
            echo "$SOURCE_PATH"
            return 0
        fi

        while IFS= read -r TAR_FILE; do
            if ! FILE_EXISTS_IN_TAR "$TAR_FILE" "$FILE_NAME" && ! FILE_EXISTS_IN_TAR "$TAR_FILE" "$FILE_NAME.lz4"; then
                continue
            fi

            LOG "- Extracting $FILE_NAME from $(basename "$TAR_FILE") for $PARTITION" >&2
            EXTRACT_FILE_FROM_TAR_TO_PATH "$TAR_FILE" "$FILE_NAME" "$SOURCE_PATH"
            echo "$SOURCE_PATH"
            return 0
        done < <(LIST_TARGET_FIRMWARE_TARS)
    done

    LOGW "Firmware descriptor source not found for $PARTITION in extracted firmware or stock Odin tars under $FW_ODIN_DIR: tried $CANDIDATES"
    return 1
}

GET_DESCRIPTOR_SOURCE_PATH()
{
    local PARTITION="$1"
    local SOURCE_PATH=""

    SOURCE_PATH="$(GET_STOCK_IMAGE_PATH "$PARTITION" || true)"
    if [ -n "$SOURCE_PATH" ] && [ -f "$SOURCE_PATH" ]; then
        echo "$SOURCE_PATH"
        return 0
    fi

    GET_FIRMWARE_DESCRIPTOR_SOURCE_PATH "$PARTITION"
}

LOG_PARTITION_SIZE_STATUS()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local SOURCE="$4"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local IMAGE_SIZE
    local ROUNDED_IMAGE_SIZE
    local MAX_IMAGE_SIZE=""

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    ROUNDED_IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"
    MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE" || true)"

    if [ -n "$MAX_IMAGE_SIZE" ]; then
        LOG "- AVB size check for $PARTITION: partition=$(FORMAT_SIZE "$PARTITION_SIZE") source=$SOURCE image=$(FORMAT_SIZE "$IMAGE_SIZE") rounded_image=$(FORMAT_SIZE "$ROUNDED_IMAGE_SIZE") max_payload=$(FORMAT_SIZE "$MAX_IMAGE_SIZE")"
    else
        LOG "- AVB size check for $PARTITION: partition=$(FORMAT_SIZE "$PARTITION_SIZE") source=$SOURCE image=$(FORMAT_SIZE "$IMAGE_SIZE") rounded_image=$(FORMAT_SIZE "$ROUNDED_IMAGE_SIZE")"
    fi
}

PRINT_AVB_SIZE_MISMATCH_DIAGNOSTICS()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local SOURCE="$4"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local IMAGE_SIZE
    local ROUNDED_IMAGE_SIZE
    local MAX_IMAGE_SIZE=""
    local MIN_PARTITION_SIZE=""
    local STOCK_IMAGE_SIZE=""

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    ROUNDED_IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"
    MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE" || true)"
    MIN_PARTITION_SIZE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND" || true)"
    STOCK_IMAGE_SIZE="$(GET_STOCK_IMAGE_PARTITION_SIZE "$PARTITION" || true)"

    LOGE "AVB size mismatch for $PARTITION: partition=$(FORMAT_SIZE "$PARTITION_SIZE") source=$SOURCE image=$(FORMAT_SIZE "$IMAGE_SIZE") rounded_image=$(FORMAT_SIZE "$ROUNDED_IMAGE_SIZE")"
    [ -n "$MAX_IMAGE_SIZE" ] && LOGE "AVB max payload for $PARTITION with current $KIND footer: $(FORMAT_SIZE "$MAX_IMAGE_SIZE")"
    [ -n "$MIN_PARTITION_SIZE" ] && LOGE "Minimum partition size required for current $PARTITION image with $KIND footer: $(FORMAT_SIZE "$MIN_PARTITION_SIZE")"
    [ -n "$STOCK_IMAGE_SIZE" ] && LOGE "Current stock $PARTITION image size on disk: $(FORMAT_SIZE "$STOCK_IMAGE_SIZE")"
}

SIGN_IMAGE()
{
    local IMAGE="$1"
    local PARTITION="$2"
    local KIND="$3"
    local PARTITION_SIZE="$4"
    local CMD=()

    PREPARE_IMAGE_FOR_CUSTOM_AVB_SIGNING "$IMAGE"
    BUILD_SIGN_IMAGE_CMD CMD "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE" "sign"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    REGISTER_PARTITION_KEY_USAGE_IF_NEEDED "$PARTITION"
    DUMP_AVB_INFO_IMAGE "$IMAGE" "$PARTITION.img"
}

SIGN_DESCRIPTOR_IMAGE()
{
    local IMAGE="$1"
    local PARTITION="$2"
    local KIND="$3"
    local PARTITION_SIZE="$4"
    local CMD=()

    PREPARE_IMAGE_FOR_DESCRIPTOR_AVB_SIGNING "$IMAGE"
    BUILD_SIGN_IMAGE_CMD CMD "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE" "sign"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    REGISTER_PARTITION_KEY_USAGE_IF_NEEDED "$PARTITION"
    DUMP_AVB_INFO_IMAGE "$IMAGE" "$PARTITION.img"
}

SIGN_BUILT_PARTITION()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local PARTITION_SIZE
    local PARTITION_SIZE_INFO=""
    local PARTITION_SIZE_SOURCE=""
    local KIND
    local CHAIN_LOCATION
    local INCLUDE_IN_TOPLEVEL="false"

    [ -f "$IMAGE" ] || return 0
    LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS" && return 0

    LOG "- Resolving AVB partition size for $PARTITION"
    PARTITION_SIZE_INFO="$(GET_PARTITION_SIZE_INFO "$PARTITION")" || {
        LOGE "Unable to determine partition size for $PARTITION"
        exit 1
    }
    PARTITION_SIZE="${PARTITION_SIZE_INFO%%|*}"
    PARTITION_SIZE_SOURCE="${PARTITION_SIZE_INFO#*|}"
    if [ -z "$PARTITION_SIZE" ]; then
        if ! LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASH_PARTITIONS" && \
                ! LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASHTREE_PARTITIONS"; then
            LOGW "Skipping optional AVB partition $PARTITION due missing partition size metadata"
            REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
            REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"
            return 0
        fi

        LOGE "Unable to determine partition size for $PARTITION"
        exit 1
    fi

    PREPARE_IMAGE_FOR_CUSTOM_AVB_SIGNING "$IMAGE"

    KIND="$(GET_SIGN_KIND "$PARTITION")"
    PARTITION_SIZE="$(RESOLVE_SIGN_PARTITION_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE")"
    LOG_PARTITION_SIZE_STATUS "$PARTITION" "$KIND" "$PARTITION_SIZE" "$PARTITION_SIZE_SOURCE"

    if ! CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE"; then
        if [ "$KIND" = "hashtree" ] && [ "$TARGET_AVB_ALLOW_HASHTREE_FALLBACK" = "true" ] && \
                CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "hash" "$PARTITION_SIZE"; then
            LOGW "Falling back to AVB hash footer for $PARTITION (hashtree does not fit within $PARTITION_SIZE bytes)"
            KIND="hash"
            SET_PARTITION_SIGN_KIND "$PARTITION" "$KIND"
        else
            PRINT_AVB_SIZE_MISMATCH_DIAGNOSTICS "$PARTITION" "$KIND" "$PARTITION_SIZE" "$PARTITION_SIZE_SOURCE"
            LOGE "Unable to fit AVB $KIND footer for $PARTITION within partition size $PARTITION_SIZE"
            exit 1
        fi
    fi

    LOG "- Signing $PARTITION.img ($KIND)"
    SIGN_IMAGE "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE"

    SHOULD_INCLUDE_IN_TOPLEVEL_VBMETA "$PARTITION" && INCLUDE_IN_TOPLEVEL="true"
    CHAIN_LOCATION="$(GET_CHAIN_LOCATION "$PARTITION")"
    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ]; then
        LOG "- Signed $PARTITION.img but not adding it to top-level vbmeta because partition descriptors are disabled"
    elif [ "$INCLUDE_IN_TOPLEVEL" = "true" ] && [ -n "$CHAIN_LOCATION" ] && [ -n "$(GET_KV_VALUE "$PARTITION" "$ORIGINAL_CHAIN_PARTITIONS")" ]; then
        APPEND_UNIQUE "ACTIVE_CHAIN_PARTITIONS" "$PARTITION=$CHAIN_LOCATION"
        APPEND_UNIQUE "INCLUDED_CHAIN_PARTITIONS" "$PARTITION=$CHAIN_LOCATION"
    elif [ "$INCLUDE_IN_TOPLEVEL" = "true" ]; then
        APPEND_UNIQUE "DIRECT_DESCRIPTOR_IMAGES" "$IMAGE"
        if [ "$KIND" = "hashtree" ]; then
            APPEND_UNIQUE "INCLUDED_HASHTREE_PARTITIONS" "$PARTITION"
        else
            APPEND_UNIQUE "INCLUDED_HASH_PARTITIONS" "$PARTITION"
        fi
    else
        LOG "- Signed $PARTITION.img but not adding it to top-level vbmeta because it is not present in the original vbmeta"
    fi
    APPEND_UNIQUE "SIGNED_PARTITIONS" "$PARTITION"
}

SIGN_EXTERNAL_DESCRIPTOR_PARTITIONS()
{
    local PARTITION
    local KIND
    local SOURCE_PATH
    local SOURCE_SIZE
    local PARTITION_SIZE
    local IMAGE
    local INCLUDE_IN_TOPLEVEL="false"

    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ]; then
        LOG "- Skipping external AVB descriptor images because top-level vbmeta partition descriptors are disabled"
        return 0
    fi

    for PARTITION in $HASH_PARTITIONS $HASHTREE_PARTITIONS; do
        INCLUDE_IN_TOPLEVEL="false"

        if LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS"; then
            continue
        fi

        KIND="$(GET_SIGN_KIND "$PARTITION")"
        SOURCE_PATH="$(GET_DESCRIPTOR_SOURCE_PATH "$PARTITION" || true)"
        if [ -z "$SOURCE_PATH" ] || [ ! -f "$SOURCE_PATH" ]; then
            if LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASH_PARTITIONS" || LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASHTREE_PARTITIONS"; then
                LOGE "Unable to resolve descriptor source for required partition $PARTITION"
                exit 1
            fi

            LOGW "Skipping optional AVB descriptor partition $PARTITION because the source image is unavailable"
            REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
            REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"
            continue
        fi
        SOURCE_SIZE="$(GET_IMAGE_SIZE "$SOURCE_PATH")" || exit 1
        PARTITION_SIZE="$(ESTIMATE_PARTITION_SIZE_FROM_IMAGE_PATH "$SOURCE_PATH" "$KIND")" || exit 1
        IMAGE="$STAGING_DIR/external_descriptors/${PARTITION}.img"

        mkdir -p "$(dirname "$IMAGE")"
        cp -fa "$SOURCE_PATH" "$IMAGE"

        LOG "- Preparing external AVB descriptor for $PARTITION from $(basename "$SOURCE_PATH"): source_image=$(FORMAT_SIZE "$SOURCE_SIZE") estimated_partition=$(FORMAT_SIZE "$PARTITION_SIZE")"
        SIGN_DESCRIPTOR_IMAGE "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE"

        SHOULD_INCLUDE_IN_TOPLEVEL_VBMETA "$PARTITION" && INCLUDE_IN_TOPLEVEL="true"
        if [ "$INCLUDE_IN_TOPLEVEL" = "true" ]; then
            APPEND_UNIQUE "DIRECT_DESCRIPTOR_IMAGES" "$IMAGE"
            if [ "$KIND" = "hashtree" ]; then
                APPEND_UNIQUE "INCLUDED_HASHTREE_PARTITIONS" "$PARTITION"
            else
                APPEND_UNIQUE "INCLUDED_HASH_PARTITIONS" "$PARTITION"
            fi
        else
            LOG "- Prepared firmware descriptor image for $PARTITION but not adding it to top-level vbmeta because it is not present in the original vbmeta"
        fi
        APPEND_UNIQUE "SIGNED_PARTITIONS" "$PARTITION"
        APPEND_UNIQUE "FIRMWARE_DESCRIPTOR_PACK_FILES" "$SOURCE_PATH"
        APPEND_UNIQUE "FIRMWARE_DESCRIPTOR_PACK_COMPONENTS" "$PARTITION=$(basename "$SOURCE_PATH")"
    done
}

DETECT_EXISTING_AVB_SIGN_KIND()
{
    local IMAGE="$1"
    local KIND=""

    [ -f "$IMAGE" ] || return 0

    KIND="$("$AVB_PYTHON_BIN" - "$AVBTOOL_PATH" "$IMAGE" <<'PY'
import importlib.util
import sys

avbtool_path, image_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

avb = module.Avb()
image = module.ImageHandler(image_path, read_only=True)
try:
    footer, _, descriptors, _ = avb._parse_image(image)
except Exception:
    raise SystemExit(0)
if footer:
    for desc in descriptors:
        if isinstance(desc, module.AvbHashtreeDescriptor):
            print('hashtree')
            raise SystemExit(0)
        if isinstance(desc, module.AvbHashDescriptor):
            print('hash')
            raise SystemExit(0)
PY
)" || true

    [ -n "$KIND" ] && echo "$KIND"
}

RESOLVE_CHAIN_PARTITION_SIGN_KIND()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local KIND=""

    KIND="$(GET_SIGN_KIND "$PARTITION")"
    if LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS" || LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
        echo "$KIND"
        return 0
    fi

    KIND="$(DETECT_EXISTING_AVB_SIGN_KIND "$IMAGE")"
    [ -n "$KIND" ] && echo "$KIND" || echo "hash"
}

SIGN_CHAIN_PARTITIONS()
{
    local ENTRY
    local PARTITION
    local KIND

    for ENTRY in $CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        [ -f "$TMP_IMG_DIR/$PARTITION.img" ] || continue
        LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS" && continue

        KIND="$(RESOLVE_CHAIN_PARTITION_SIGN_KIND "$PARTITION")"
        SET_PARTITION_SIGN_KIND "$PARTITION" "$KIND"
        LOG "- Signing chained AVB partition $PARTITION using $KIND footer"
        SIGN_BUILT_PARTITION "$PARTITION"
    done
}

BUILD_OPTIONAL_PROPS()
{
    local ENTRY
    local KEY
    local VALUE
    local SECURITY_PATCH_OVERRIDE="${TARGET_AVB_VBMETA_SECURITY_PATCH_OVERRIDE:-2026-02-01}"
    local BOOT_OS_VERSION
    local BOOT_PATCH
    local SYSTEM_OS_VERSION
    local SYSTEM_PATCH
    local VENDOR_OS_VERSION
    local VENDOR_PATCH

    VBMETA_PROPS=()

    if [ "$TARGET_AVB_USE_ORIGINAL_VBMETA_PROPS" = "true" ] && [ -n "$ORIGINAL_VBMETA_PROPS" ]; then
        for ENTRY in $ORIGINAL_VBMETA_PROPS; do
            KEY="${ENTRY%%=*}"
            VALUE="${ENTRY#*=}"
            case "$KEY" in
                "com.android.build.boot.security_patch" | \
                "com.android.build.system.security_patch" | \
                "com.android.build.vendor.security_patch")
                    VALUE="$SECURITY_PATCH_OVERRIDE"
                    ;;
            esac
            VBMETA_PROPS+=("--prop" "$KEY:$VALUE")
        done
        LOG_PARTITION_SET "Using original vbmeta props" "$ORIGINAL_VBMETA_PROPS"
        AVB_DEBUG_LOG "Overriding vbmeta boot/system/vendor security_patch props to $SECURITY_PATCH_OVERRIDE"
        return 0
    fi

    BOOT_OS_VERSION="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/boot.img_metadata.txt" "os_version")"
    BOOT_PATCH="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/boot.img_metadata.txt" "os_patch_level")"
    SYSTEM_OS_VERSION="$(GET_PROP "system" "ro.build.version.release")"
    SYSTEM_PATCH="$(GET_PROP "system" "ro.build.version.security_patch")"
    VENDOR_OS_VERSION="$(GET_PROP "vendor" "ro.vendor.build.version.release")"
    [ -z "$VENDOR_OS_VERSION" ] && VENDOR_OS_VERSION="$(GET_PROP "vendor" "ro.build.version.release")"
    VENDOR_PATCH="$(GET_PROP "vendor" "ro.vendor.build.version.security_patch")"
    [ -z "$VENDOR_PATCH" ] && VENDOR_PATCH="$(GET_PROP "vendor" "ro.build.version.security_patch")"
    BOOT_PATCH="$SECURITY_PATCH_OVERRIDE"
    SYSTEM_PATCH="$SECURITY_PATCH_OVERRIDE"
    VENDOR_PATCH="$SECURITY_PATCH_OVERRIDE"

    [ -n "$BOOT_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.boot.os_version:$BOOT_OS_VERSION")
    [ -n "$BOOT_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.boot.security_patch:$BOOT_PATCH")
    [ -n "$SYSTEM_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.system.os_version:$SYSTEM_OS_VERSION")
    [ -n "$SYSTEM_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.system.security_patch:$SYSTEM_PATCH")
    [ -n "$VENDOR_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.vendor.os_version:$VENDOR_OS_VERSION")
    [ -n "$VENDOR_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.vendor.security_patch:$VENDOR_PATCH")
}

BUILD_ORIGINAL_KERNEL_CMDLINE_DESCRIPTOR_IMAGE()
{
    local OUTPUT="$STAGING_DIR/original_kernel_cmdline_descriptors.img"

    [ -s "$ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE" ] || return 1

    "$AVB_PYTHON_BIN" - "$AVBTOOL_PATH" "$ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE" "$OUTPUT" <<'PY'
import base64
import importlib.util
import sys

avbtool_path, input_path, output_path = sys.argv[1:4]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

descriptors = []
with open(input_path, 'r', encoding='utf-8') as fh:
    for raw_line in fh:
        raw_line = raw_line.rstrip('\n')
        if not raw_line:
            continue
        flags, cmdline_b64 = raw_line.split('\t', 1)
        desc = module.AvbKernelCmdlineDescriptor()
        desc.flags = int(flags)
        desc.kernel_cmdline = base64.b64decode(cmdline_b64).decode('utf-8')
        descriptors.append(desc)

avb = module.Avb()
blob = avb._generate_vbmeta_blob(
    'NONE',
    None,
    None,
    descriptors,
    None,
    None,
    0,
    0,
    0,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    0,
)

with open(output_path, 'wb') as fh:
    fh.write(blob)
PY

    echo "$OUTPUT"
}

MAKE_TOPLEVEL_VBMETA()
{
    local ENTRY
    local PARTITION
    local LOCATION
    local CMD=()
    local PUBLIC_KEY_BLOB=""
    local CHAIN_OPTION="--chain_partition"
    local ORIGINAL_KERNEL_CMDLINE_IMAGE=""

    BUILD_OPTIONAL_PROPS

    CMD=(
        make_vbmeta_image
        --output "$TMP_IMG_DIR/vbmeta.img"
        --algorithm "$VBMETA_SIGN_ALGORITHM"
        --rollback_index "$TARGET_AVB_ROLLBACK_INDEX"
        --rollback_index_location "$TARGET_AVB_ROLLBACK_INDEX_LOCATION"
        --key "$VBMETA_SIGN_KEY_PATH"
    )

    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" = "true" ]; then
        for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
            CMD+=(--include_descriptors_from_image "$ENTRY")
        done
    else
        LOG "- Creating vbmeta without hash, hashtree, or chain partition descriptors"
    fi

    ORIGINAL_KERNEL_CMDLINE_IMAGE="$(BUILD_ORIGINAL_KERNEL_CMDLINE_DESCRIPTOR_IMAGE || true)"
    if [ -n "$ORIGINAL_KERNEL_CMDLINE_IMAGE" ] && [ -f "$ORIGINAL_KERNEL_CMDLINE_IMAGE" ]; then
        CMD+=(--include_descriptors_from_image "$ORIGINAL_KERNEL_CMDLINE_IMAGE")
    fi

    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" = "true" ]; then
        for ENTRY in $ACTIVE_CHAIN_PARTITIONS; do
            PARTITION="${ENTRY%%=*}"
            LOCATION="${ENTRY#*=}"
            RESOLVE_PARTITION_SIGNING_CONFIG "$PARTITION" "$(GET_SIGN_KIND "$PARTITION")"
            if [ "$PARTITION_SIGN_ALGORITHM" = "NONE" ] || [ -z "$PARTITION_SIGN_KEY_PATH" ]; then
                LOGE "Chained partition $PARTITION must use a real signing key"
                exit 1
            fi
            PUBLIC_KEY_BLOB="$(GET_CHAIN_PUBLIC_KEY_BLOB "$PARTITION" "$PARTITION_SIGN_KEY_PATH")"
            CHAIN_OPTION="--chain_partition"
            [ "$PARTITION_SIGN_DO_NOT_USE_AB" = "true" ] && CHAIN_OPTION="--chain_partition_do_not_use_ab"
            CMD+=("$CHAIN_OPTION" "${PARTITION}:${LOCATION}:$PUBLIC_KEY_BLOB")
        done
    fi

    if [ "${#VBMETA_PROPS[@]}" -gt 0 ]; then
        CMD+=("${VBMETA_PROPS[@]}")
    fi

    if [ -n "$ORIGINAL_VBMETA_RELEASE_STRING" ]; then
        CMD+=(--internal_release_string "$ORIGINAL_VBMETA_RELEASE_STRING")
    fi

    APPEND_ARGS_FROM_STRING CMD "$TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS"

    LOG "- Creating vbmeta.img"
    LOG_PARTITION_SET "Direct descriptor images" "$DIRECT_DESCRIPTOR_IMAGES"
    LOG_PARTITION_SET "Active chain partitions" "$ACTIVE_CHAIN_PARTITIONS"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    if [ -n "$ORIGINAL_VBMETA_TRAILER_PATH" ] && [ -f "$ORIGINAL_VBMETA_TRAILER_PATH" ]; then
        LOG "- Appending original vbmeta trailer for Samsung compatibility: marker=$ORIGINAL_VBMETA_TRAILER_MARKER size=$(FORMAT_SIZE "$ORIGINAL_VBMETA_TRAILER_SIZE")"
        cat "$ORIGINAL_VBMETA_TRAILER_PATH" >> "$TMP_IMG_DIR/vbmeta.img" || exit 1
    fi
    DUMP_AVB_INFO_IMAGE "$TMP_IMG_DIR/vbmeta.img" "vbmeta.img"
}

MAKE_VBMETA_SAMSUNG()
{
    local PARTITION
    local ENTRY
    local REQUESTED_PARTITIONS="$TARGET_AVB_VBMETA_SAMSUNG_PARTITIONS"
    local CMD=()
    local DESCRIPTOR_IMAGES=""
    local ALGORITHM="${ORIGINAL_VBMETA_SAMSUNG_ALGORITHM:-$VBMETA_SIGN_ALGORITHM}"
    local ROLLBACK_INDEX="${ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX:-$TARGET_AVB_ROLLBACK_INDEX}"
    local ROLLBACK_INDEX_LOCATION="${ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX_LOCATION:-$TARGET_AVB_ROLLBACK_INDEX_LOCATION}"
    local RELEASE_STRING="${ORIGINAL_VBMETA_SAMSUNG_RELEASE_STRING:-}"

    VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS=""

    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ]; then
        LOG "- Skipping vbmeta_samsung.img because partition descriptors are disabled"
        return 0
    fi

    for PARTITION in $REQUESTED_PARTITIONS; do
        for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
            case "$(basename "$ENTRY")" in
                "$PARTITION.img" | "$PARTITION.bin" | "$PARTITION")
                    APPEND_UNIQUE "DESCRIPTOR_IMAGES" "$ENTRY"
                    APPEND_UNIQUE "VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS" "$PARTITION"
                    break
                    ;;
            esac
        done

        if ! LIST_HAS_ITEM "$PARTITION" "$VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS"; then
            LOGW "Skipping vbmeta_samsung descriptor for $PARTITION because it is not included in the normal vbmeta descriptor set"
        fi
    done

    if [ -z "$DESCRIPTOR_IMAGES" ]; then
        LOGW "No descriptor images available for vbmeta_samsung.img; skipping"
        return 0
    fi

    CMD=(
        make_vbmeta_image
        --output "$TMP_IMG_DIR/vbmeta_samsung.img"
        --algorithm "$ALGORITHM"
        --rollback_index "$ROLLBACK_INDEX"
        --rollback_index_location "$ROLLBACK_INDEX_LOCATION"
        --key "$VBMETA_SIGN_KEY_PATH"
    )

    for ENTRY in $DESCRIPTOR_IMAGES; do
        CMD+=(--include_descriptors_from_image "$ENTRY")
    done

    for ENTRY in $ORIGINAL_VBMETA_SAMSUNG_PROPS; do
        CMD+=(--prop "${ENTRY%%=*}:${ENTRY#*=}")
    done

    if [ -n "$RELEASE_STRING" ]; then
        CMD+=(--internal_release_string "$RELEASE_STRING")
    fi

    APPEND_ARGS_FROM_STRING CMD "$TARGET_AVB_MAKE_VBMETA_SAMSUNG_IMAGE_ARGS"

    LOG "- Creating vbmeta_samsung.img"
    LOG_PARTITION_SET "vbmeta_samsung requested partitions" "$REQUESTED_PARTITIONS"
    LOG_PARTITION_SET "vbmeta_samsung descriptor partitions" "$VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS"
    LOG_PARTITION_SET "vbmeta_samsung descriptor images" "$DESCRIPTOR_IMAGES"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    if [ -n "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH" ] && [ -f "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH" ]; then
        LOG "- Appending original vbmeta_samsung trailer for Samsung compatibility: marker=$ORIGINAL_VBMETA_SAMSUNG_TRAILER_MARKER size=$(FORMAT_SIZE "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_SIZE")"
        cat "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH" >> "$TMP_IMG_DIR/vbmeta_samsung.img" || exit 1
    fi
    DUMP_AVB_INFO_IMAGE "$TMP_IMG_DIR/vbmeta_samsung.img" "vbmeta_samsung.img"
}

VERIFY_SIGNED_AVB()
{
    local VERIFY_DIR="$STAGING_DIR/verify"
    local ENTRY
    local PARTITION
    local LOCATION
    local VERIFY_CMD=()
    local PUBLIC_KEY_BLOB=""
    local SOURCE_PATH=""

    rm -rf "$VERIFY_DIR"
    mkdir -p "$VERIFY_DIR"

    SOURCE_PATH="$(GET_ABSOLUTE_PATH "$TMP_IMG_DIR/vbmeta.img")"
    ln -sf "$SOURCE_PATH" "$VERIFY_DIR/vbmeta.img"
    if [ -f "$TMP_IMG_DIR/vbmeta_samsung.img" ]; then
        SOURCE_PATH="$(GET_ABSOLUTE_PATH "$TMP_IMG_DIR/vbmeta_samsung.img")"
        ln -sf "$SOURCE_PATH" "$VERIFY_DIR/vbmeta_samsung.img"
    fi

    for PARTITION in $SIGNED_PARTITIONS; do
        [ -f "$TMP_IMG_DIR/$PARTITION.img" ] || continue
        SOURCE_PATH="$(GET_ABSOLUTE_PATH "$TMP_IMG_DIR/$PARTITION.img")"
        ln -sf "$SOURCE_PATH" "$VERIFY_DIR/$PARTITION.img"
        ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$TMP_IMG_DIR/$PARTITION.img" "$PARTITION.img"
    done

    for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
        PARTITION="$(basename "$ENTRY")"
        [ -f "$ENTRY" ] || continue
        if [ ! -e "$VERIFY_DIR/$PARTITION" ]; then
            SOURCE_PATH="$(GET_ABSOLUTE_PATH "$ENTRY")"
            ln -sf "$SOURCE_PATH" "$VERIFY_DIR/$PARTITION"
        fi
        ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$ENTRY" "$PARTITION"
    done

    ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$TMP_IMG_DIR/vbmeta.img" "vbmeta.img"

    VERIFY_CMD=(
        verify_image
        --image "$VERIFY_DIR/vbmeta.img"
        --key "$VBMETA_SIGN_KEY_PATH"
    )

    for ENTRY in $ACTIVE_CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        LOCATION="${ENTRY#*=}"
        RESOLVE_PARTITION_SIGNING_CONFIG "$PARTITION" "$(GET_SIGN_KIND "$PARTITION")"
        PUBLIC_KEY_BLOB="$(GET_CHAIN_PUBLIC_KEY_BLOB "$PARTITION" "$PARTITION_SIGN_KEY_PATH")"
        VERIFY_CMD+=(--expected_chain_partition "${PARTITION}:${LOCATION}:$PUBLIC_KEY_BLOB")
    done

    LOG "- Verifying top-level vbmeta image"
    RUN_AVBTOOL "${VERIFY_CMD[@]}" || exit 1

    if [ -f "$TMP_IMG_DIR/vbmeta_samsung.img" ]; then
        ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$TMP_IMG_DIR/vbmeta_samsung.img" "vbmeta_samsung.img"
        LOG "- Verifying vbmeta_samsung image"
        RUN_AVBTOOL verify_image \
            --image "$VERIFY_DIR/vbmeta_samsung.img" \
            --key "$VBMETA_SIGN_KEY_PATH" || exit 1
    fi

    for ENTRY in $ACTIVE_CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        RESOLVE_PARTITION_SIGNING_CONFIG "$PARTITION" "$(GET_SIGN_KIND "$PARTITION")"
        LOG "- Verifying chained vbmeta image: $PARTITION.img"
        RUN_AVBTOOL verify_image \
            --image "$VERIFY_DIR/$PARTITION.img" \
            --key "$PARTITION_SIGN_KEY_PATH" || exit 1
    done
}

PRINT_KEY_SUMMARY()
{
    local CURRENT_LABEL=""
    local PRIVATE_KEY=""
    local PUBLIC_KEY=""
    local DIGEST=""
    local ALGORITHM=""

    [ -f "$KEY_EXPORT_REPORT" ] || return 0

    LOG "- AVB public key blobs exported for custom key setup:"
    while IFS='=' read -r KEY VALUE; do
        case "$KEY" in
            "label")
                CURRENT_LABEL="$VALUE"
                ;;
            "algorithm")
                ALGORITHM="$VALUE"
                ;;
            "private_key")
                PRIVATE_KEY="$VALUE"
                ;;
            "public_key_blob")
                PUBLIC_KEY="$VALUE"
                ;;
            "public_key_sha256")
                DIGEST="$VALUE"
                LOG "  * $CURRENT_LABEL: alg=$ALGORITHM key=$PRIVATE_KEY blob=$PACK_DIR/$PUBLIC_KEY sha256=$DIGEST"
                ;;
        esac
    done < "$KEY_EXPORT_REPORT"
}

CREATE_IMAGE_PACK()
{
    local ENTRY
    local PARTITION
    local KIND
    local FILE_NAME

    [ -d "$PACK_DIR" ] && rm -rf "$PACK_DIR"
    mkdir -p "$PACK_DIR"

    while IFS= read -r ENTRY; do
        cp -fa "$ENTRY" "$PACK_DIR/$(basename "$ENTRY")"
    done < <(find "$TMP_IMG_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "up_param.bin" \))

    if [ -d "$STAGING_DIR/keys" ]; then
        mkdir -p "$PACK_DIR/keys"
        while IFS= read -r ENTRY; do
            cp -fa "$ENTRY" "$PACK_DIR/keys/$(basename "$ENTRY")"
        done < <(find "$STAGING_DIR/keys" -maxdepth 1 -type f -name "*.avbpubkey")
    fi

    for ENTRY in $FIRMWARE_DESCRIPTOR_PACK_FILES; do
        [ -f "$ENTRY" ] || continue
        FILE_NAME="$(basename "$ENTRY")"
        cp -fa "$ENTRY" "$PACK_DIR/$FILE_NAME"
    done

    {
        echo "device=$TARGET_CODENAME"
        echo "firmware=$TARGET_FIRMWARE"
        echo "algorithm=$VBMETA_SIGN_ALGORITHM"
        echo "include_partition_descriptors=$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS"
        echo "preserve_samsung_signatures=$TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES"
        echo "vbmeta_key_path=$VBMETA_SIGN_KEY_PATH"
        echo "vbmeta_public_key_blob=keys/vbmeta.avbpubkey"
        if [ -f "$STAGING_DIR/keys/vbmeta.avbpubkey" ]; then
            echo "vbmeta_public_key_sha256=$(CALCULATE_SHA256 "$STAGING_DIR/keys/vbmeta.avbpubkey")"
        fi
        for PARTITION in $INCLUDED_HASH_PARTITIONS; do
            echo "hash_partition=$PARTITION"
        done
        for PARTITION in $INCLUDED_HASHTREE_PARTITIONS; do
            echo "hashtree_partition=$PARTITION"
        done
        for PARTITION in $INCLUDED_CHAIN_PARTITIONS; do
            echo "chain_partition=$PARTITION"
        done
        for PARTITION in $VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS; do
            echo "vbmeta_samsung_partition=$PARTITION"
        done
        for ENTRY in $FIRMWARE_DESCRIPTOR_PACK_COMPONENTS; do
            echo "firmware_component=$ENTRY"
        done
    } > "$PACK_DIR/avb_manifest.txt"

    if [ -f "$KEY_EXPORT_REPORT" ]; then
        cp -fa "$KEY_EXPORT_REPORT" "$PACK_DIR/avb_keys.txt"
    fi

    if [ "$TARGET_AVB_CREATE_IMAGE_PACK_ZIP" = "true" ]; then
        rm -f "$PACK_ZIP"
        pushd "$PACK_DIR" > /dev/null
        EVAL "7z a -tzip -mx=$TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL \"$PACK_ZIP\" ./*" || exit 1
        popd > /dev/null
    else
        rm -f "$PACK_ZIP"
        LOG "- Skipping signed image zip compression (TARGET_AVB_CREATE_IMAGE_PACK_ZIP=false)"
    fi

    PRINT_KEY_SUMMARY
}

PRINT_USAGE()
{
    echo "Usage: sign_avb_images <tmp_img_dir>" >&2
}

trap 'rm -rf "$STAGING_DIR"' EXIT INT

if [ "$#" -ne 1 ] || [ ! -d "$TMP_IMG_DIR" ]; then
    PRINT_USAGE
    exit 1
fi

INIT_DEFAULTS
SETUP_AVBTOOL
PARSE_ORIGINAL_VBMETA_LAYOUT
PARSE_ORIGINAL_VBMETA_SAMSUNG_LAYOUT
ADOPT_ORIGINAL_VBMETA_DEFAULTS
MERGE_LAYOUT
ASSERT_REQUIRED_RE_SIGN_COVERAGE
RESOLVE_TOPLEVEL_SIGNING_CONFIG
REGISTER_KEY_USAGE "vbmeta" "$VBMETA_SIGN_KEY_PATH" "$VBMETA_SIGN_ALGORITHM"

for PARTITION in $HASH_PARTITIONS $HASHTREE_PARTITIONS; do
    SIGN_BUILT_PARTITION "$PARTITION"
done

SIGN_CHAIN_PARTITIONS
SIGN_EXTERNAL_DESCRIPTOR_PARTITIONS
MAKE_TOPLEVEL_VBMETA
MAKE_VBMETA_SAMSUNG
VERIFY_SIGNED_AVB
CREATE_IMAGE_PACK

exit 0
