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
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_CSC="$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_MODEL_ALT="${TARGET_FIRMWARE_MODEL#SM-}"
PACK_DIR="${TARGET_AVB_IMAGE_PACK_DIR:-$OUT_DIR/target/$TARGET_CODENAME/signed_images}"
PACK_ZIP="${TARGET_AVB_IMAGE_PACK_ZIP:-$OUT_DIR/${TARGET_CODENAME}_signed_images.zip}"
STAGING_DIR="$(mktemp -d "$TMP_DIR/avb_sign.XXXXXX")"
AOSP_AVB_PEM="$OUT_DIR/security/aosp_platform_avb.pem"
AOSP_PLATFORM_PK8="$SRC_DIR/security/aosp_platform.pk8"
AOSP_PLATFORM_KEY_SENTINEL="auto_aosp_platform"
UPSTREAM_AVBTOOL_PATH="$SRC_DIR/platform_external_avb-master/avbtool.py"
DIRECT_DESCRIPTOR_IMAGES=""
ACTIVE_CHAIN_PARTITIONS=""
ORIGINAL_HASH_PARTITIONS=""
ORIGINAL_HASHTREE_PARTITIONS=""
ORIGINAL_CHAIN_PARTITIONS=""
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
BL_TAR_PATH=""
EXCLUDED_VBMETA_PARTITIONS="bootloader"
KNOWN_FIRMWARE_DESCRIPTOR_PARTITIONS="ldfw tzsw keystorage harx fld"
REQUIRED_RE_SIGN_PARTITIONS="boot init_boot vendor_boot dtbo recovery"
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

TARGET_SUPPORTS_FIRMWARE_DESCRIPTOR_PARTITIONS()
{
    [[ "$TARGET_NAME" == Galaxy\ S20* ]] || [[ "$TARGET_NAME" == Galaxy\ S21* ]]
}

IS_KNOWN_FIRMWARE_DESCRIPTOR_PARTITION()
{
    local PARTITION="$1"

    LIST_HAS_ITEM "$PARTITION" "$KNOWN_FIRMWARE_DESCRIPTOR_PARTITIONS"
}

IS_ENABLED_FIRMWARE_DESCRIPTOR_PARTITION()
{
    local PARTITION="$1"

    TARGET_SUPPORTS_FIRMWARE_DESCRIPTOR_PARTITIONS || return 1
    LIST_HAS_ITEM "$PARTITION" "$TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS"
}

INIT_DEFAULTS()
{
    TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT="${TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT:-true}"
    TARGET_AVB_KEY_PATH="${TARGET_AVB_KEY_PATH:-$AOSP_PLATFORM_KEY_SENTINEL}"
    if [ -z "${TARGET_AVB_ALGORITHM:-}" ]; then
        if [ "$TARGET_AVB_KEY_PATH" = "$AOSP_PLATFORM_KEY_SENTINEL" ] || [ "$TARGET_AVB_KEY_PATH" = "none" ]; then
            TARGET_AVB_ALGORITHM="SHA256_RSA2048"
        else
            TARGET_AVB_ALGORITHM="SHA256_RSA4096"
        fi
    fi
    TARGET_AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-$UPSTREAM_AVBTOOL_PATH}"
    TARGET_AVBTOOL_PYTHON="${TARGET_AVBTOOL_PYTHON:-none}"
    TARGET_AVB_HASH_PARTITIONS="${TARGET_AVB_HASH_PARTITIONS:-boot vendor_boot init_boot}"
    TARGET_AVB_HASHTREE_PARTITIONS="${TARGET_AVB_HASHTREE_PARTITIONS:-system vendor product odm system_ext vendor_dlkm odm_dlkm system_dlkm prism optics}"
    TARGET_AVB_CHAIN_PARTITIONS="${TARGET_AVB_CHAIN_PARTITIONS:-recovery=6 dtbo=7 prism=12 optics=13}"
    TARGET_AVB_ORIGINAL_VBMETA_PATH="${TARGET_AVB_ORIGINAL_VBMETA_PATH:-none}"
    TARGET_AVB_ALLOW_HASHTREE_FALLBACK="${TARGET_AVB_ALLOW_HASHTREE_FALLBACK:-false}"
    TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL="${TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL:-1}"
    TARGET_AVB_CREATE_IMAGE_PACK_ZIP="${TARGET_AVB_CREATE_IMAGE_PACK_ZIP:-false}"
    TARGET_AVB_ROLLBACK_INDEX="${TARGET_AVB_ROLLBACK_INDEX:-0}"
    TARGET_AVB_ROLLBACK_INDEX_LOCATION="${TARGET_AVB_ROLLBACK_INDEX_LOCATION:-0}"
    TARGET_AVB_HASH_ALGORITHM="${TARGET_AVB_HASH_ALGORITHM:-sha256}"
    TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS="${TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS:-}"
    TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS="${TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS:-}"
    TARGET_AVB_FIRMWARE_IMAGE_MAP="${TARGET_AVB_FIRMWARE_IMAGE_MAP:-ldfw=ldfw.img tzsw=tzsw.img keystorage=keystorage.bin harx=harx.bin fld=fld.bin}"

    TARGET_SUPPORTS_FIRMWARE_DESCRIPTOR_PARTITIONS || TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS=""

    if ! [[ "$TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL" =~ ^[0-9]$ ]]; then
        LOGW "Invalid TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL: $TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL (expected 0-9). Using 1."
        TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL="1"
    fi
    if [ "$TARGET_AVB_CREATE_IMAGE_PACK_ZIP" != "true" ] && [ "$TARGET_AVB_CREATE_IMAGE_PACK_ZIP" != "false" ]; then
        LOGW "Invalid TARGET_AVB_CREATE_IMAGE_PACK_ZIP: $TARGET_AVB_CREATE_IMAGE_PACK_ZIP (expected true|false). Using false."
        TARGET_AVB_CREATE_IMAGE_PACK_ZIP="false"
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

    $TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT || return 0

    ORIGINAL_VBMETA="$(GET_ORIGINAL_VBMETA_PATH)"
    [ -f "$ORIGINAL_VBMETA" ] || return 0
    [ -n "$AVB_PYTHON_BIN" ] || return 0
    [ -f "$AVBTOOL_PATH" ] || return 0

    DUMP_AVB_INFO_IMAGE "$ORIGINAL_VBMETA" "original vbmeta"

    while IFS=' ' read -r KIND VALUE; do
        case "$KIND" in
            "hash")
                APPEND_UNIQUE "ORIGINAL_HASH_PARTITIONS" "$VALUE"
                ;;
            "hashtree")
                APPEND_UNIQUE "ORIGINAL_HASHTREE_PARTITIONS" "$VALUE"
                ;;
            "chain")
                APPEND_UNIQUE "ORIGINAL_CHAIN_PARTITIONS" "$VALUE"
                ;;
        esac
    done < <(
        "$AVB_PYTHON_BIN" - "$AVBTOOL_PATH" "$ORIGINAL_VBMETA" <<'PY'
import importlib.util
import sys

avbtool_path, image_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

avb = module.Avb()
image = module.ImageHandler(image_path, read_only=True)
_, _, descriptors, _ = avb._parse_image(image)

for desc in descriptors:
    if isinstance(desc, module.AvbHashtreeDescriptor):
        print(f'hashtree {desc.partition_name}')
    elif isinstance(desc, module.AvbHashDescriptor):
        print(f'hash {desc.partition_name}')
    elif isinstance(desc, module.AvbChainPartitionDescriptor):
        print(f'chain {desc.partition_name}={desc.rollback_index_location}')
PY
    )

    LOG_PARTITION_SET "Original vbmeta hash partitions" "$ORIGINAL_HASH_PARTITIONS"
    LOG_PARTITION_SET "Original vbmeta hashtree partitions" "$ORIGINAL_HASHTREE_PARTITIONS"
    LOG_PARTITION_SET "Original vbmeta chain partitions" "$ORIGINAL_CHAIN_PARTITIONS"
}

MERGE_LAYOUT()
{
    local ENTRY
    local PARTITION
    local LOCATION

    HASH_PARTITIONS="$TARGET_AVB_HASH_PARTITIONS"
    HASHTREE_PARTITIONS="$TARGET_AVB_HASHTREE_PARTITIONS"
    CHAIN_PARTITIONS="$TARGET_AVB_CHAIN_PARTITIONS"

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

    for PARTITION in $KNOWN_FIRMWARE_DESCRIPTOR_PARTITIONS; do
        if IS_ENABLED_FIRMWARE_DESCRIPTOR_PARTITION "$PARTITION"; then
            continue
        fi

        if LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS"; then
            LOG "- Removing $PARTITION from AVB hash descriptors for this target"
            REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
        fi
        if LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
            LOG "- Removing $PARTITION from AVB hashtree descriptors for this target"
            REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"
        fi
        LOCATION="$(GET_KV_VALUE "$PARTITION" "$CHAIN_PARTITIONS")"
        if [ -n "$LOCATION" ]; then
            LOG "- Removing $PARTITION from AVB chain descriptors for this target"
            REMOVE_KV_ITEM "CHAIN_PARTITIONS" "$PARTITION"
        fi
    done

    for ENTRY in $ORIGINAL_HASH_PARTITIONS; do
        if IS_EXCLUDED_AVB_PARTITION "$ENTRY"; then
            LOG "- Ignoring original vbmeta hash descriptor for $ENTRY; verification for this partition is disabled"
            continue
        fi
        if IS_KNOWN_FIRMWARE_DESCRIPTOR_PARTITION "$ENTRY" && ! IS_ENABLED_FIRMWARE_DESCRIPTOR_PARTITION "$ENTRY"; then
            LOG "- Ignoring original vbmeta hash descriptor for $ENTRY; this firmware partition is not enabled for this target"
            continue
        fi
        APPEND_UNIQUE "HASH_PARTITIONS" "$ENTRY"
    done

    for ENTRY in $ORIGINAL_HASHTREE_PARTITIONS; do
        if IS_EXCLUDED_AVB_PARTITION "$ENTRY"; then
            LOG "- Ignoring original vbmeta hashtree descriptor for $ENTRY; verification for this partition is disabled"
            continue
        fi
        if IS_KNOWN_FIRMWARE_DESCRIPTOR_PARTITION "$ENTRY" && ! IS_ENABLED_FIRMWARE_DESCRIPTOR_PARTITION "$ENTRY"; then
            LOG "- Ignoring original vbmeta hashtree descriptor for $ENTRY; this firmware partition is not enabled for this target"
            continue
        fi
        APPEND_UNIQUE "HASHTREE_PARTITIONS" "$ENTRY"
    done

    for ENTRY in $ORIGINAL_CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        if IS_EXCLUDED_AVB_PARTITION "$PARTITION"; then
            LOG "- Ignoring original vbmeta chain descriptor for $PARTITION; verification for this partition is disabled"
            continue
        fi
        if IS_KNOWN_FIRMWARE_DESCRIPTOR_PARTITION "$PARTITION" && ! IS_ENABLED_FIRMWARE_DESCRIPTOR_PARTITION "$PARTITION"; then
            LOG "- Ignoring original vbmeta chain descriptor for $PARTITION; this firmware partition is not enabled for this target"
            continue
        fi
        APPEND_UNIQUE "CHAIN_PARTITIONS" "$ENTRY"
    done

    LOG_PARTITION_SET "Merged AVB hash partitions" "$HASH_PARTITIONS"
    LOG_PARTITION_SET "Merged AVB hashtree partitions" "$HASHTREE_PARTITIONS"
    LOG_PARTITION_SET "Merged AVB chain partitions" "$CHAIN_PARTITIONS"
    LOG_PARTITION_SET "Enabled firmware descriptor partitions" "$TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS"
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

ENSURE_AOSP_AVB_KEY()
{
    if [ ! -f "$AOSP_PLATFORM_PK8" ]; then
        LOGE "AOSP platform private key not found: $AOSP_PLATFORM_PK8"
        exit 1
    fi
    if ! command -v openssl &> /dev/null; then
        LOGE "openssl is required to extract an AVB PEM key from aosp_platform.pk8"
        exit 1
    fi
    mkdir -p "$(dirname "$AOSP_AVB_PEM")"
    if [ ! -f "$AOSP_AVB_PEM" ] || [ "$AOSP_PLATFORM_PK8" -nt "$AOSP_AVB_PEM" ]; then
        LOG "- Extracting AVB PEM key from aosp_platform.pk8"
        openssl pkcs8 -inform DER -nocrypt \
            -in "$AOSP_PLATFORM_PK8" \
            -out "$AOSP_AVB_PEM" || exit 1
        chmod 600 "$AOSP_AVB_PEM"
    fi
}

RESOLVE_AVB_KEY_PATH()
{
    local KEY_VALUE="$1"

    if [ "$KEY_VALUE" = "$AOSP_PLATFORM_KEY_SENTINEL" ]; then
        ENSURE_AOSP_AVB_KEY
        echo "$AOSP_AVB_PEM"
        return 0
    fi

    if [ -n "$KEY_VALUE" ] && [ "$KEY_VALUE" != "none" ]; then
        [ -f "$KEY_VALUE" ] || {
            LOGE "AVB key not found: $KEY_VALUE"
            exit 1
        }
        echo "$KEY_VALUE"
    fi
}

RESOLVE_TOPLEVEL_SIGNING_CONFIG()
{
    local KEY_VALUE="$TARGET_AVB_KEY_PATH"

    VBMETA_SIGN_ALGORITHM="$TARGET_AVB_ALGORITHM"
    if [ "$KEY_VALUE" = "$AOSP_PLATFORM_KEY_SENTINEL" ] && [ "$VBMETA_SIGN_ALGORITHM" != "NONE" ] && \
            [ "$VBMETA_SIGN_ALGORITHM" != "SHA256_RSA2048" ]; then
        LOG "- Using auto AOSP AVB key for top-level vbmeta, forcing algorithm to SHA256_RSA2048"
        VBMETA_SIGN_ALGORITHM="SHA256_RSA2048"
    fi

    VBMETA_SIGN_KEY_PATH="$(RESOLVE_AVB_KEY_PATH "$KEY_VALUE")"
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
    [ -z "$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION" ] && [ -n "$CHAIN_LOCATION" ] && PARTITION_SIGN_ROLLBACK_INDEX_LOCATION="$CHAIN_LOCATION"
    [ -z "$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION" ] && PARTITION_SIGN_ROLLBACK_INDEX_LOCATION="0"

    PARTITION_SIGN_DO_NOT_USE_AB="$(GET_PARTITION_VAR_VALUE "$PARTITION" "DO_NOT_USE_AB")"
    [ -z "$PARTITION_SIGN_DO_NOT_USE_AB" ] && PARTITION_SIGN_DO_NOT_USE_AB="false"

    if [ "$KIND" = "hashtree" ]; then
        PARTITION_SIGN_EXTRA_ARGS="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ADD_HASHTREE_FOOTER_ARGS")"
    else
        PARTITION_SIGN_EXTRA_ARGS="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ADD_HASH_FOOTER_ARGS")"
    fi

    KEY_VALUE="$(GET_PARTITION_VAR_VALUE "$PARTITION" "KEY_PATH")"
    [ -z "$KEY_VALUE" ] && KEY_VALUE="$TARGET_AVB_KEY_PATH"
    if [ "$KEY_VALUE" = "$AOSP_PLATFORM_KEY_SENTINEL" ] && [ "$PARTITION_SIGN_ALGORITHM" != "NONE" ] && \
            [ "$PARTITION_SIGN_ALGORITHM" != "SHA256_RSA2048" ]; then
        LOG "- Using auto AOSP AVB key for $PARTITION, forcing algorithm to SHA256_RSA2048"
        PARTITION_SIGN_ALGORITHM="SHA256_RSA2048"
    fi
    PARTITION_SIGN_KEY_PATH="$(RESOLVE_AVB_KEY_PATH "$KEY_VALUE")"

    if [ "$PARTITION_SIGN_ALGORITHM" = "NONE" ]; then
        LOGE "Partition $PARTITION must use a real AVB signing algorithm"
        exit 1
    fi

    if [ -z "$PARTITION_SIGN_KEY_PATH" ]; then
        LOGE "Missing AVB key for partition $PARTITION (algorithm=$PARTITION_SIGN_ALGORITHM)"
        exit 1
    fi

    AVB_DEBUG_LOG "Partition signing config for $PARTITION: kind=$KIND algorithm=$PARTITION_SIGN_ALGORITHM key=$PARTITION_SIGN_KEY_PATH hash_algorithm=$PARTITION_SIGN_HASH_ALGORITHM rollback_index=$PARTITION_SIGN_ROLLBACK_INDEX rollback_index_location=$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION do_not_use_ab=$PARTITION_SIGN_DO_NOT_USE_AB extra_args=${PARTITION_SIGN_EXTRA_ARGS:-<none>}"

    if [ -n "$PARTITION_SIGN_KEY_PATH" ] && { [ -n "$CHAIN_LOCATION" ] || \
            [ "$PARTITION_SIGN_KEY_PATH" != "$VBMETA_SIGN_KEY_PATH" ] || \
            [ "$PARTITION_SIGN_ALGORITHM" != "$VBMETA_SIGN_ALGORITHM" ]; }; then
        REGISTER_KEY_USAGE "$PARTITION" "$PARTITION_SIGN_KEY_PATH" "$PARTITION_SIGN_ALGORITHM"
    fi
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
        [ "$MID" -le "$LOWER_BOUND" ] && MID="$((LOWER_BOUND + 4096))"

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
    REMOVE_SAMSUNG_SIGNATURES_IF_PRESENT "$IMAGE"
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

LOCATE_TARGET_BL_TAR()
{
    local PATTERN

    if [ -n "$BL_TAR_PATH" ] && [ -f "$BL_TAR_PATH" ]; then
        echo "$BL_TAR_PATH"
        return 0
    fi

    for PATTERN in "BL_${TARGET_FIRMWARE_MODEL}*.md5" "BL_${TARGET_FIRMWARE_MODEL_ALT}*.md5" "BL_*.md5"; do
        BL_TAR_PATH="$(find "$ODIN_DIR/${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}" -name "$PATTERN" | sort -r | head -n 1)"
        [ -n "$BL_TAR_PATH" ] && break
    done

    if [ -z "$BL_TAR_PATH" ]; then
        LOGE "Unable to locate BL tar for $TARGET_FIRMWARE_MODEL/$TARGET_FIRMWARE_CSC in $ODIN_DIR/${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}"
        exit 1
    fi

    AVB_DEBUG_LOG "Using BL tar for firmware descriptors: $BL_TAR_PATH"
    echo "$BL_TAR_PATH"
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
    local TAR_FILE=""

    FILE_NAME="$(GET_FIRMWARE_DESCRIPTOR_FILENAME "$PARTITION")"
    [ -n "$FILE_NAME" ] || {
        LOGE "Missing TARGET_AVB_FIRMWARE_IMAGE_MAP entry for $PARTITION"
        exit 1
    }

    SOURCE_PATH="$STAGING_DIR/fw_odin/$FILE_NAME"
    if [ ! -f "$SOURCE_PATH" ]; then
        TAR_FILE="$(LOCATE_TARGET_BL_TAR)"
        LOG "- Extracting $FILE_NAME from $(basename "$TAR_FILE") for $PARTITION"
        EXTRACT_FILE_FROM_TAR_TO_PATH "$TAR_FILE" "$FILE_NAME" "$SOURCE_PATH"
    fi

    echo "$SOURCE_PATH"
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

    [ -f "$IMAGE" ] || return 0
    LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS" && return 0

    PREPARE_IMAGE_FOR_CUSTOM_AVB_SIGNING "$IMAGE"

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

    CHAIN_LOCATION="$(GET_CHAIN_LOCATION "$PARTITION")"
    if [ -n "$CHAIN_LOCATION" ]; then
        APPEND_UNIQUE "ACTIVE_CHAIN_PARTITIONS" "$PARTITION=$CHAIN_LOCATION"
    else
        APPEND_UNIQUE "DIRECT_DESCRIPTOR_IMAGES" "$IMAGE"
    fi
    APPEND_UNIQUE "SIGNED_PARTITIONS" "$PARTITION"
}

SIGN_FIRMWARE_DESCRIPTOR_PARTITIONS()
{
    local PARTITION
    local KIND
    local SOURCE_PATH
    local SOURCE_SIZE
    local PARTITION_SIZE
    local IMAGE

    for PARTITION in $TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS; do
        if ! LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS" && ! LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
            continue
        fi

        if LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS"; then
            continue
        fi

        KIND="$(GET_SIGN_KIND "$PARTITION")"
        SOURCE_PATH="$(GET_FIRMWARE_DESCRIPTOR_SOURCE_PATH "$PARTITION")"
        SOURCE_SIZE="$(GET_IMAGE_SIZE "$SOURCE_PATH")" || exit 1
        PARTITION_SIZE="$(ESTIMATE_PARTITION_SIZE_FROM_IMAGE_PATH "$SOURCE_PATH" "$KIND")" || exit 1
        IMAGE="$STAGING_DIR/firmware_descriptors/${PARTITION}.img"

        mkdir -p "$(dirname "$IMAGE")"
        cp -fa "$SOURCE_PATH" "$IMAGE"

        LOG "- Preparing firmware AVB descriptor for $PARTITION from $(basename "$SOURCE_PATH"): source_image=$(FORMAT_SIZE "$SOURCE_SIZE") estimated_partition=$(FORMAT_SIZE "$PARTITION_SIZE")"
        SIGN_DESCRIPTOR_IMAGE "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE"

        APPEND_UNIQUE "DIRECT_DESCRIPTOR_IMAGES" "$IMAGE"
        APPEND_UNIQUE "SIGNED_PARTITIONS" "$PARTITION"
        APPEND_UNIQUE "FIRMWARE_DESCRIPTOR_PACK_FILES" "$SOURCE_PATH"
    done
}

BUILD_OPTIONAL_PROPS()
{
    local BOOT_OS_VERSION
    local BOOT_PATCH
    local SYSTEM_OS_VERSION
    local SYSTEM_PATCH
    local VENDOR_OS_VERSION
    local VENDOR_PATCH

    VBMETA_PROPS=()

    BOOT_OS_VERSION="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/boot.img_metadata.txt" "os_version")"
    BOOT_PATCH="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/boot.img_metadata.txt" "os_patch_level")"
    SYSTEM_OS_VERSION="$(GET_PROP "system" "ro.build.version.release")"
    SYSTEM_PATCH="$(GET_PROP "system" "ro.build.version.security_patch")"
    VENDOR_OS_VERSION="$(GET_PROP "vendor" "ro.vendor.build.version.release")"
    [ -z "$VENDOR_OS_VERSION" ] && VENDOR_OS_VERSION="$(GET_PROP "vendor" "ro.build.version.release")"
    VENDOR_PATCH="$(GET_PROP "vendor" "ro.vendor.build.version.security_patch")"
    [ -z "$VENDOR_PATCH" ] && VENDOR_PATCH="$(GET_PROP "vendor" "ro.build.version.security_patch")"

    [ -n "$BOOT_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.boot.os_version:$BOOT_OS_VERSION")
    [ -n "$BOOT_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.boot.security_patch:$BOOT_PATCH")
    [ -n "$SYSTEM_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.system.os_version:$SYSTEM_OS_VERSION")
    [ -n "$SYSTEM_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.system.security_patch:$SYSTEM_PATCH")
    [ -n "$VENDOR_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.vendor.os_version:$VENDOR_OS_VERSION")
    [ -n "$VENDOR_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.vendor.security_patch:$VENDOR_PATCH")
}

MAKE_TOPLEVEL_VBMETA()
{
    local ENTRY
    local PARTITION
    local LOCATION
    local CMD=()
    local PUBLIC_KEY_BLOB=""
    local CHAIN_OPTION="--chain_partition"

    BUILD_OPTIONAL_PROPS

    CMD=(
        make_vbmeta_image
        --output "$TMP_IMG_DIR/vbmeta.img"
        --algorithm "$VBMETA_SIGN_ALGORITHM"
        --rollback_index "$TARGET_AVB_ROLLBACK_INDEX"
        --rollback_index_location "$TARGET_AVB_ROLLBACK_INDEX_LOCATION"
        --key "$VBMETA_SIGN_KEY_PATH"
    )

    for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
        CMD+=(--include_descriptors_from_image "$ENTRY")
    done

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

    if [ "${#VBMETA_PROPS[@]}" -gt 0 ]; then
        CMD+=("${VBMETA_PROPS[@]}")
    fi

    APPEND_ARGS_FROM_STRING CMD "$TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS"

    LOG "- Creating vbmeta.img"
    LOG_PARTITION_SET "Direct descriptor images" "$DIRECT_DESCRIPTOR_IMAGES"
    LOG_PARTITION_SET "Active chain partitions" "$ACTIVE_CHAIN_PARTITIONS"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    DUMP_AVB_INFO_IMAGE "$TMP_IMG_DIR/vbmeta.img" "vbmeta.img"
}

VERIFY_SIGNED_AVB()
{
    local VERIFY_DIR="$STAGING_DIR/verify"
    local ENTRY
    local PARTITION
    local LOCATION
    local VERIFY_CMD=()
    local PUBLIC_KEY_BLOB=""

    rm -rf "$VERIFY_DIR"
    mkdir -p "$VERIFY_DIR"

    ln -sf "$TMP_IMG_DIR/vbmeta.img" "$VERIFY_DIR/vbmeta.img"

    for PARTITION in $SIGNED_PARTITIONS; do
        [ -f "$TMP_IMG_DIR/$PARTITION.img" ] || continue
        ln -sf "$TMP_IMG_DIR/$PARTITION.img" "$VERIFY_DIR/$PARTITION.img"
        ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$TMP_IMG_DIR/$PARTITION.img" "$PARTITION.img"
    done

    for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
        PARTITION="$(basename "$ENTRY")"
        [ -f "$ENTRY" ] || continue
        [ -e "$VERIFY_DIR/$PARTITION" ] || ln -sf "$ENTRY" "$VERIFY_DIR/$PARTITION"
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
        echo "vbmeta_key_path=$VBMETA_SIGN_KEY_PATH"
        echo "vbmeta_public_key_blob=keys/vbmeta.avbpubkey"
        if [ -f "$STAGING_DIR/keys/vbmeta.avbpubkey" ]; then
            echo "vbmeta_public_key_sha256=$(CALCULATE_SHA256 "$STAGING_DIR/keys/vbmeta.avbpubkey")"
        fi
        for PARTITION in $HASH_PARTITIONS; do
            KIND="$(GET_SIGN_KIND "$PARTITION")"
            [ "$KIND" = "hash" ] && echo "hash_partition=$PARTITION"
        done
        for PARTITION in $HASHTREE_PARTITIONS; do
            KIND="$(GET_SIGN_KIND "$PARTITION")"
            [ "$KIND" = "hashtree" ] && echo "hashtree_partition=$PARTITION"
        done
        for PARTITION in $ACTIVE_CHAIN_PARTITIONS; do
            echo "chain_partition=$PARTITION"
        done
        for ENTRY in $FIRMWARE_DESCRIPTOR_PACK_FILES; do
            [ -f "$ENTRY" ] || continue
            PARTITION="$(basename "$ENTRY")"
            echo "firmware_component=$PARTITION"
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
MERGE_LAYOUT
ASSERT_REQUIRED_RE_SIGN_COVERAGE
RESOLVE_TOPLEVEL_SIGNING_CONFIG
REGISTER_KEY_USAGE "vbmeta" "$VBMETA_SIGN_KEY_PATH" "$VBMETA_SIGN_ALGORITHM"

for PARTITION in $HASH_PARTITIONS $HASHTREE_PARTITIONS; do
    SIGN_BUILT_PARTITION "$PARTITION"
done

SIGN_FIRMWARE_DESCRIPTOR_PARTITIONS
MAKE_TOPLEVEL_VBMETA
VERIFY_SIGNED_AVB
CREATE_IMAGE_PACK

exit 0
