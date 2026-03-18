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
TARGET_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
TARGET_MODEL_ALT="${TARGET_MODEL#SM-}"
BL_TAR=""
for PATTERN in "BL_${TARGET_MODEL}*.md5" "BL_${TARGET_MODEL_ALT}*.md5" "BL_*.md5"; do
    BL_TAR="$(find "$ODIN_DIR/$TARGET_FIRMWARE_PATH" -name "$PATTERN" | sort -r | head -n 1)"
    [ -n "$BL_TAR" ] && break
done
PACK_DIR="${TARGET_AVB_IMAGE_PACK_DIR:-$OUT_DIR/target/$TARGET_CODENAME/signed_images}"
PACK_ZIP="${TARGET_AVB_IMAGE_PACK_ZIP:-$OUT_DIR/${TARGET_CODENAME}_signed_images.zip}"
STAGING_DIR="$(mktemp -d "$TMP_DIR/avb_sign.XXXXXX")"
PUBLIC_KEY_BLOB="$STAGING_DIR/avb_public_key.bin"
AOSP_AVB_PEM="$OUT_DIR/security/aosp_platform_avb.pem"
AOSP_PLATFORM_PK8="$SRC_DIR/security/aosp_platform.pk8"
AOSP_PLATFORM_KEY_SENTINEL="auto_aosp_platform"
DIRECT_DESCRIPTOR_IMAGES=""
ACTIVE_CHAIN_PARTITIONS=""
ORIGINAL_HASH_PARTITIONS=""
ORIGINAL_HASHTREE_PARTITIONS=""
ORIGINAL_CHAIN_PARTITIONS=""
HASH_PARTITIONS=""
HASHTREE_PARTITIONS=""
CHAIN_PARTITIONS=""
BOOTLOADER_IMAGE_MAP=""
AVBTOOL_PATH=""
AVBTOOL_CMD=()
SIGNED_PARTITIONS=""
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
    TARGET_AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-none}"
    TARGET_AVBTOOL_PYTHON="${TARGET_AVBTOOL_PYTHON:-none}"
    TARGET_AVB_HASH_PARTITIONS="${TARGET_AVB_HASH_PARTITIONS:-boot vendor_boot init_boot bootloader ldfw tzsw keystorage harx fld}"
    TARGET_AVB_HASHTREE_PARTITIONS="${TARGET_AVB_HASHTREE_PARTITIONS:-system vendor product odm system_ext vendor_dlkm odm_dlkm system_dlkm prism optics}"
    TARGET_AVB_CHAIN_PARTITIONS="${TARGET_AVB_CHAIN_PARTITIONS:-recovery=6 dtbo=7 prism=12 optics=13}"
    TARGET_AVB_BOOTLOADER_IMAGE_MAP="${TARGET_AVB_BOOTLOADER_IMAGE_MAP:-bootloader=sboot.bin ldfw=ldfw.img tzsw=tzsw.img keystorage=keystorage.bin harx=harx.bin fld=fld.bin}"
    TARGET_AVB_ORIGINAL_VBMETA_PATH="${TARGET_AVB_ORIGINAL_VBMETA_PATH:-none}"
    TARGET_AVB_ALLOW_HASHTREE_FALLBACK="${TARGET_AVB_ALLOW_HASHTREE_FALLBACK:-true}"
    TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL="${TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL:-1}"
    TARGET_AVB_CREATE_IMAGE_PACK_ZIP="${TARGET_AVB_CREATE_IMAGE_PACK_ZIP:-false}"

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
        python3 - "$ORIGINAL_VBMETA" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, 'rb') as fp:
    data = fp.read()

if data[:4] != b'AVB0':
    raise SystemExit(0)

fmt = '>2I2QI11QII48s80s'
header = struct.unpack(fmt, data[4:4 + struct.calcsize(fmt)])
auth_size = header[2]
desc_off = header[13]
desc_size = header[14]
aux_start = 256 + auth_size
offset = aux_start + desc_off
end = offset + desc_size

while offset < end:
    tag, num_bytes = struct.unpack('>QQ', data[offset:offset + 16])
    body = data[offset + 16:offset + 16 + num_bytes]

    if tag == 1:
        partition_name_len = struct.unpack('>I', body[88:92])[0]
        name = body[164:164 + partition_name_len].decode('utf-8', 'replace')
        print('hashtree {}'.format(name))
    elif tag == 2:
        partition_name_len = struct.unpack('>I', body[40:44])[0]
        name = body[116:116 + partition_name_len].decode('utf-8', 'replace')
        print('hash {}'.format(name))
    elif tag == 4:
        rollback_index_location, partition_name_len, _public_key_len = struct.unpack('>III', body[:12])
        name = body[76:76 + partition_name_len].decode('utf-8', 'replace')
        print('chain {}={}'.format(name, rollback_index_location))

    offset += 16 + num_bytes
PY
    )
}

MERGE_LAYOUT()
{
    local ENTRY

    HASH_PARTITIONS="$TARGET_AVB_HASH_PARTITIONS"
    HASHTREE_PARTITIONS="$TARGET_AVB_HASHTREE_PARTITIONS"
    CHAIN_PARTITIONS="$TARGET_AVB_CHAIN_PARTITIONS"
    BOOTLOADER_IMAGE_MAP="$TARGET_AVB_BOOTLOADER_IMAGE_MAP"

    for ENTRY in $ORIGINAL_HASH_PARTITIONS; do
        APPEND_UNIQUE "HASH_PARTITIONS" "$ENTRY"
    done

    for ENTRY in $ORIGINAL_HASHTREE_PARTITIONS; do
        APPEND_UNIQUE "HASHTREE_PARTITIONS" "$ENTRY"
    done

    for ENTRY in $ORIGINAL_CHAIN_PARTITIONS; do
        APPEND_UNIQUE "CHAIN_PARTITIONS" "$ENTRY"
    done
}

SETUP_AVBTOOL()
{
    if [ "$TARGET_AVBTOOL_PATH" != "none" ]; then
        AVBTOOL_PATH="$TARGET_AVBTOOL_PATH"
    elif [ -x "$SRC_DIR/tools/bin/avbtool" ]; then
        AVBTOOL_PATH="$SRC_DIR/tools/bin/avbtool"
    elif [ -x "$OUT_DIR/tools/bin/avbtool" ]; then
        AVBTOOL_PATH="$OUT_DIR/tools/bin/avbtool"
    elif command -v avbtool &> /dev/null; then
        AVBTOOL_PATH="$(command -v avbtool)"
    elif [ -f "$SRC_DIR/../scripts/security/avbtool" ]; then
        AVBTOOL_PATH="$SRC_DIR/../scripts/security/avbtool"
    else
        LOGE "Unable to locate avbtool. Set TARGET_AVBTOOL_PATH in your target config"
        exit 1
    fi

    AVBTOOL_CMD=()
    if [ "$TARGET_AVBTOOL_PYTHON" != "none" ]; then
        AVBTOOL_CMD+=("$TARGET_AVBTOOL_PYTHON")
    fi
    AVBTOOL_CMD+=("$AVBTOOL_PATH")

    if ! "${AVBTOOL_CMD[@]}" version &> /dev/null; then
        LOGE "Configured avbtool could not be executed. Check TARGET_AVBTOOL_PATH/TARGET_AVBTOOL_PYTHON"
        exit 1
    fi

    if [ "$TARGET_AVB_KEY_PATH" = "none" ] || [ "$TARGET_AVB_KEY_PATH" = "$AOSP_PLATFORM_KEY_SENTINEL" ]; then
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
        if [ "$TARGET_AVB_ALGORITHM" != "SHA256_RSA2048" ]; then
            LOG "- Using auto AOSP AVB key, forcing algorithm to SHA256_RSA2048"
            TARGET_AVB_ALGORITHM="SHA256_RSA2048"
        fi
        TARGET_AVB_KEY_PATH="$AOSP_AVB_PEM"
    fi

    if [ ! -f "$TARGET_AVB_KEY_PATH" ]; then
        LOGE "TARGET_AVB_KEY_PATH must point to a readable AVB private key"
        exit 1
    fi
}

RUN_AVBTOOL()
{
    "${AVBTOOL_CMD[@]}" "$@"
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

CALCULATE_AVB_MAX_IMAGE_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local CMD=()
    local OUTPUT=""

    if [ "$KIND" = "hashtree" ]; then
        CMD=(
            add_hashtree_footer
            --calc_max_image_size
            --partition_size "$PARTITION_SIZE"
            --partition_name "$PARTITION"
            --algorithm "$TARGET_AVB_ALGORITHM"
            --key "$TARGET_AVB_KEY_PATH"
        )
    else
        CMD=(
            add_hash_footer
            --calc_max_image_size
            --partition_size "$PARTITION_SIZE"
            --partition_name "$PARTITION"
            --algorithm "$TARGET_AVB_ALGORITHM"
            --key "$TARGET_AVB_KEY_PATH"
        )
    fi

    OUTPUT="$(RUN_AVBTOOL "${CMD[@]}" 2> /dev/null | tail -n 1 | tr -d '[:space:]')" || return 1
    [[ "$OUTPUT" =~ ^[0-9]+$ ]] || return 1

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

GET_PARTITION_SIZE()
{
    local PARTITION="$1"
    local VALUE=""
    local KIND

    VALUE="$(GET_EXPLICIT_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE" && return 0

    VALUE="$(GET_METADATA_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE" && return 0

    VALUE="$(GET_STOCK_IMAGE_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE" && return 0

    KIND="$(GET_SIGN_KIND "$PARTITION")"
    if IS_DYNAMIC_AVB_PARTITION "$PARTITION"; then
        LOG "- Resolving dynamic AVB partition size for $PARTITION from the built image" >&2

        VALUE="$(ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE "$PARTITION" "$KIND")"
        if [ -n "$VALUE" ]; then
            LOGW "Estimated AVB partition size for dynamic partition $PARTITION: $VALUE" >&2
            echo "$VALUE"
            return 0
        fi

        VALUE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND")"
        if [ -n "$VALUE" ]; then
            LOGW "Calculated AVB partition size for dynamic partition $PARTITION from the built image: $VALUE" >&2
            echo "$VALUE"
            return 0
        fi
    fi

    LOGE "Unable to determine a fixed partition size for $PARTITION. Re-extract firmware metadata or set TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE"
    return 1
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

ERASE_FOOTER_IF_PRESENT()
{
    local IMAGE="$1"

    if RUN_AVBTOOL info_image --image "$IMAGE" &> /dev/null; then
        RUN_AVBTOOL erase_footer --image "$IMAGE" || exit 1
    fi
}

SIGN_IMAGE()
{
    local IMAGE="$1"
    local PARTITION="$2"
    local KIND="$3"
    local PARTITION_SIZE="$4"

    ERASE_FOOTER_IF_PRESENT "$IMAGE"

    if [ "$KIND" = "hashtree" ]; then
        RUN_AVBTOOL add_hashtree_footer \
            --image "$IMAGE" \
            --partition_name "$PARTITION" \
            --partition_size "$PARTITION_SIZE" \
            --algorithm "$TARGET_AVB_ALGORITHM" \
            --key "$TARGET_AVB_KEY_PATH" || exit 1
    else
        RUN_AVBTOOL add_hash_footer \
            --image "$IMAGE" \
            --partition_name "$PARTITION" \
            --partition_size "$PARTITION_SIZE" \
            --algorithm "$TARGET_AVB_ALGORITHM" \
            --key "$TARGET_AVB_KEY_PATH" || exit 1
    fi
}

SIGN_BUILT_PARTITION()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local PARTITION_SIZE
    local KIND
    local CHAIN_LOCATION

    [ -f "$IMAGE" ] || return 0
    LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS" && return 0

    LOG "- Resolving AVB partition size for $PARTITION"
    PARTITION_SIZE="$(GET_PARTITION_SIZE "$PARTITION")"
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

    if ! CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE"; then
        if [ "$KIND" = "hashtree" ] && [ "$TARGET_AVB_ALLOW_HASHTREE_FALLBACK" = "true" ] && \
                CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "hash" "$PARTITION_SIZE"; then
            LOGW "Falling back to AVB hash footer for $PARTITION (hashtree does not fit within $PARTITION_SIZE bytes)"
            KIND="hash"
            SET_PARTITION_SIGN_KIND "$PARTITION" "$KIND"
        else
            LOGE "Unable to fit AVB $KIND footer for $PARTITION within partition size $PARTITION_SIZE"
            exit 1
        fi
    fi

    LOG "- Signing $PARTITION.img ($KIND)"
    SIGN_IMAGE "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE"

    CHAIN_LOCATION="$(GET_KV_VALUE "$PARTITION" "$CHAIN_PARTITIONS")"
    if [ -n "$CHAIN_LOCATION" ]; then
        APPEND_UNIQUE "ACTIVE_CHAIN_PARTITIONS" "$PARTITION=$CHAIN_LOCATION"
    else
        APPEND_UNIQUE "DIRECT_DESCRIPTOR_IMAGES" "$IMAGE"
    fi
    APPEND_UNIQUE "SIGNED_PARTITIONS" "$PARTITION"
}

EXTRACT_BOOTLOADER_IMAGE()
{
    local PARTITION="$1"
    local DEST="$2"
    local SOURCE_NAME
    local MEMBER=""
    local CANDIDATE

    [ -f "$BL_TAR" ] || return 1

    SOURCE_NAME="$(GET_KV_VALUE "$PARTITION" "$BOOTLOADER_IMAGE_MAP")"
    [ -n "$SOURCE_NAME" ] || return 1

    for CANDIDATE in "$SOURCE_NAME" "$SOURCE_NAME.ext4" "$SOURCE_NAME.lz4" "$SOURCE_NAME.ext4.lz4"; do
        if FILE_EXISTS_IN_TAR "$BL_TAR" "$CANDIDATE"; then
            MEMBER="$CANDIDATE"
            break
        fi
    done

    [ -n "$MEMBER" ] || return 1

    mkdir -p "$(dirname "$DEST")"

    if [[ "$MEMBER" == *".lz4" ]]; then
        local TMP_LZ4="$DEST.lz4"
        EVAL "tar xf \"$BL_TAR\" -C \"$(dirname "$DEST")\" \"$MEMBER\"" || return 1
        mv -f "$(dirname "$DEST")/$(basename "$MEMBER")" "$TMP_LZ4"
        EVAL "lz4 -d --rm \"$TMP_LZ4\" \"$DEST\"" || return 1
    else
        EVAL "tar xf \"$BL_TAR\" -C \"$(dirname "$DEST")\" \"$MEMBER\"" || return 1
        mv -f "$(dirname "$DEST")/$(basename "$MEMBER")" "$DEST"
    fi

    return 0
}

SIGN_BOOTLOADER_DESCRIPTORS()
{
    local PARTITION
    local IMAGE
    local KIND
    local PARTITION_SIZE

    for PARTITION in bootloader ldfw tzsw keystorage harx fld; do
        if ! LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS" && ! LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
            continue
        fi

        IMAGE="$STAGING_DIR/bl/$PARTITION.img"
        if ! EXTRACT_BOOTLOADER_IMAGE "$PARTITION" "$IMAGE"; then
            if LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASH_PARTITIONS"; then
                LOGE "Missing BL source image for $PARTITION in $BL_TAR"
                exit 1
            fi
            continue
        fi

        PARTITION_SIZE="$(wc -c "$IMAGE" | awk '{print $1}')"
        KIND="$(GET_SIGN_KIND "$PARTITION")"

        LOG "- Adding $PARTITION descriptor from stock BL image"
        SIGN_IMAGE "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE"
        APPEND_UNIQUE "DIRECT_DESCRIPTOR_IMAGES" "$IMAGE"
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

    RUN_AVBTOOL extract_public_key --key "$TARGET_AVB_KEY_PATH" --output "$PUBLIC_KEY_BLOB" || exit 1

    BUILD_OPTIONAL_PROPS

    CMD=(
        make_vbmeta_image
        --output "$TMP_IMG_DIR/vbmeta.img"
        --algorithm "$TARGET_AVB_ALGORITHM"
        --key "$TARGET_AVB_KEY_PATH"
    )

    for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
        CMD+=(--include_descriptors_from_image "$ENTRY")
    done

    for ENTRY in $ACTIVE_CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        LOCATION="${ENTRY#*=}"
        CMD+=(--chain_partition "${PARTITION}:${LOCATION}:$PUBLIC_KEY_BLOB")
    done

    if [ "${#VBMETA_PROPS[@]}" -gt 0 ]; then
        CMD+=("${VBMETA_PROPS[@]}")
    fi

    LOG "- Creating vbmeta.img"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
}

CREATE_IMAGE_PACK()
{
    local ENTRY
    local PARTITION
    local KIND

    [ -d "$PACK_DIR" ] && rm -rf "$PACK_DIR"
    mkdir -p "$PACK_DIR"

    while IFS= read -r ENTRY; do
        cp -fa "$ENTRY" "$PACK_DIR/$(basename "$ENTRY")"
    done < <(find "$TMP_IMG_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "up_param.bin" \))

    {
        echo "device=$TARGET_CODENAME"
        echo "firmware=$TARGET_FIRMWARE"
        echo "algorithm=$TARGET_AVB_ALGORITHM"
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
    } > "$PACK_DIR/avb_manifest.txt"

    if [ "$TARGET_AVB_CREATE_IMAGE_PACK_ZIP" = "true" ]; then
        rm -f "$PACK_ZIP"
        pushd "$PACK_DIR" > /dev/null
        EVAL "7z a -tzip -mx=$TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL \"$PACK_ZIP\" ./*" || exit 1
        popd > /dev/null
    else
        rm -f "$PACK_ZIP"
        LOG "- Skipping signed image zip compression (TARGET_AVB_CREATE_IMAGE_PACK_ZIP=false)"
    fi
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
PARSE_ORIGINAL_VBMETA_LAYOUT
MERGE_LAYOUT
SETUP_AVBTOOL

for PARTITION in $HASH_PARTITIONS $HASHTREE_PARTITIONS; do
    case "$PARTITION" in
        "bootloader" | "ldfw" | "tzsw" | "keystorage" | "harx" | "fld")
            continue
            ;;
        *)
            SIGN_BUILT_PARTITION "$PARTITION"
            ;;
    esac
done

SIGN_BOOTLOADER_DESCRIPTORS
MAKE_TOPLEVEL_VBMETA
CREATE_IMAGE_PACK

exit 0
