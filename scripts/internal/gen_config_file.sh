#!/usr/bin/env bash
#
# Copyright (C) 2025 Salvo Giangreco
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
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# [
source "$SRC_DIR/scripts/utils/common_utils.sh" || exit 1

trap '[ $? -ne 0 ] && rm -f "$OUT_DIR/config.sh"' EXIT

GET_BUILD_VAR()
{
    local VALUE

    if [ "$#" -ge 2 ]; then
        if [ ! "${!1}" ]; then
            VALUE="$2"
            VALUE="${VALUE//\\/\\\\}"
            VALUE="${VALUE//\"/\\\"}"
            echo "${1}=\"${VALUE}\""
            return 0
        fi
    else
        _CHECK_NON_EMPTY_PARAM "$1" "${!1}" || exit 1
    fi

    VALUE="${!1}"
    VALUE="${VALUE//\\/\\\\}"
    VALUE="${VALUE//\"/\\\"}"
    echo "${1}=\"${VALUE}\""
    return 0
}

GET_DEFAULT_ROM_IS_OFFICIAL()
{
    if [ "${ROM_IS_OFFICIAL:-}" = "true" ] || [ "${ROM_IS_OFFICIAL:-}" = "false" ]; then
        echo "$ROM_IS_OFFICIAL"
    elif [ "${ROM_TYPE:-default}" = "official" ]; then
        echo "true"
    else
        echo "false"
    fi
}

SANITIZE_CONFIG_ENV()
{
    local VAR

    while IFS= read -r VAR; do
        case "$VAR" in
            SOURCE_*|TARGET_*|ROM_VERSION|ROM_CODENAME|ROM_DISPLAY_NAME|ROM_TYPE|ROM_BUILD_TIMESTAMP)
                unset "$VAR"
                ;;
        esac
    done < <(compgen -v)
}

GET_DEFAULT_ODIN_SUPER_IMAGE()
{
    if [ "${TARGET_SUPER_PARTITION_SIZE:-0}" -eq 0 ]; then
        echo "false"
    elif [[ "$TARGET_NAME" == Galaxy\ S20* ]] || [[ "$TARGET_NAME" == Galaxy\ S21* ]]; then
        echo "true"
    else
        echo "false"
    fi
}

GET_DEFAULT_KEEP_ORIGINAL_SIGN()
{
    if [[ "$ROM_ENABLE_AVB" == "true" ]]; then
        echo "false"
    else
        echo "true"
    fi
}

GET_DEFAULT_AVB_KEY_PATH()
{
    if [[ "$ROM_ENABLE_AVB" == "true" ]]; then
        echo "$SRC_DIR/security/avb/creckerrom_avb_private.pem"
    else
        echo "none"
    fi
}

GET_DEFAULT_AVB_ALGORITHM()
{
    if [[ "$ROM_ENABLE_AVB" == "true" ]]; then
        echo "SHA256_RSA4096"
    else
        echo "SHA256_RSA4096"
    fi
}

GET_DEFAULT_AVB_INCLUDE_PARTITION_DESCRIPTORS()
{
    echo "${ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS:-true}"
}

GET_DEFAULT_AVB_VBMETA_ONLY()
{
    echo "${ROM_AVB_VBMETA_ONLY:-false}"
}

GET_DEFAULT_PLATFORM_KEY_SOURCE_PEM()
{
    local KEY_PATH
    KEY_PATH="$(GET_DEFAULT_AVB_KEY_PATH)"
    [ "$KEY_PATH" = "none" ] && KEY_PATH="$SRC_DIR/security/avb/creckerrom_avb_private.pem"
    echo "$KEY_PATH"
}

GET_DEFAULT_PLATFORM_CERT_X509_PATH()
{
    echo "$SRC_DIR/security/creckerrom_platform.x509.pem"
}

GET_DEFAULT_PLATFORM_CERT_PK8_PATH()
{
    echo "$SRC_DIR/security/creckerrom_platform.pk8"
}

GET_DEFAULT_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS()
{
    echo ""
}

GET_DEFAULT_AVB_FIRMWARE_IMAGE_MAP()
{
    echo ""
}

GET_DEFAULT_ODIN_EXTRA_PARTITIONS()
{
    GET_DEFAULT_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS
}

IS_DEFAULT_AVB_CONFIG_VAR()
{
    case "$1" in
        "TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT" | \
        "TARGET_AVB_KEY_PATH" | \
        "TARGET_AVB_ALGORITHM" | \
        "TARGET_AVBTOOL_PATH" | \
        "TARGET_AVBTOOL_PYTHON" | \
        "TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" | \
        "TARGET_AVB_VBMETA_ONLY" | \
        "TARGET_AVB_HASH_PARTITIONS" | \
        "TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS" | \
        "TARGET_AVB_FIRMWARE_IMAGE_MAP" | \
        "TARGET_AVB_HASHTREE_PARTITIONS" | \
        "TARGET_AVB_CHAIN_PARTITIONS" | \
        "TARGET_AVB_ORIGINAL_VBMETA_PATH" | \
        "TARGET_AVB_FLASH_VBMETA_IN_ZIP" | \
        "TARGET_AVB_ALLOW_HASHTREE_FALLBACK" | \
        "TARGET_AVB_CREATE_IMAGE_PACK_ZIP" | \
        "TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL" | \
        "TARGET_AVB_ROLLBACK_INDEX" | \
        "TARGET_AVB_ROLLBACK_INDEX_LOCATION" | \
        "TARGET_AVB_HASH_ALGORITHM" | \
        "TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS" | \
        "TARGET_ODIN_EXTRA_PARTITIONS" | \
        "TARGET_ODIN_EXTRA_IMAGE_MAP")
            return 0
            ;;
    esac

    return 1
}

EMIT_EXTRA_AVB_VARS()
{
    local VAR

    while IFS= read -r VAR; do
        IS_DEFAULT_AVB_CONFIG_VAR "$VAR" && continue
        GET_BUILD_VAR "$VAR"
    done < <(compgen -v | grep '^TARGET_AVB_' || true)
}
# ]

if [ $# -ne 1 ]; then
    echo "Usage: gen_config_file <target>" >&2
    exit 1
elif [ ! -f "$SRC_DIR/target/$1/config.sh" ]; then
    LOGE "File not found: target/$1/config.sh"
    exit 1
else
    SANITIZE_CONFIG_ENV
    source "$SRC_DIR/unica/configs/version.sh" || exit 1
    source "$SRC_DIR/target/$1/config.sh" || exit 1
fi

SINGLE_SYSTEM_IMAGE="$TARGET_SINGLE_SYSTEM_IMAGE"
[[ "$TARGET_SINGLE_SYSTEM_IMAGE" == "essi" ]] && SINGLE_SYSTEM_IMAGE="essi_64"

FORCE_EXT4_IMAGES="${FORCE_EXT4_IMAGES:-false}"
if [[ "$FORCE_EXT4_IMAGES" != "true" ]] && [[ "$FORCE_EXT4_IMAGES" != "false" ]]; then
    LOGE "FORCE_EXT4_IMAGES must be \"true\" or \"false\" (got: $FORCE_EXT4_IMAGES)"
    exit 1
fi

ROM_ENABLE_ENCRYPTION="${ROM_ENABLE_ENCRYPTION:-false}"
if [[ "$ROM_ENABLE_ENCRYPTION" != "true" ]] && \
        [[ "$ROM_ENABLE_ENCRYPTION" != "false" ]]; then
    LOGE "ROM_ENABLE_ENCRYPTION must be \"true\" or \"false\" (got: $ROM_ENABLE_ENCRYPTION)"
    exit 1
fi
TARGET_ENABLE_ENCRYPTION="$ROM_ENABLE_ENCRYPTION"

ROM_DEBLOAT_LEVEL="${ROM_DEBLOAT_LEVEL:-default}"
if [[ "$ROM_DEBLOAT_LEVEL" != "default" ]] && \
        [[ "$ROM_DEBLOAT_LEVEL" != "none" ]] && \
        [[ "$ROM_DEBLOAT_LEVEL" != "ultra" ]]; then
    LOGE "ROM_DEBLOAT_LEVEL must be \"default\", \"none\" or \"ultra\" (got: $ROM_DEBLOAT_LEVEL)"
    exit 1
fi

ROM_BUILD_FLASHABLE_ZIP="${ROM_BUILD_FLASHABLE_ZIP:-false}"
if [[ "$ROM_BUILD_FLASHABLE_ZIP" != "true" ]] && \
        [[ "$ROM_BUILD_FLASHABLE_ZIP" != "false" ]]; then
    LOGE "ROM_BUILD_FLASHABLE_ZIP must be \"true\" or \"false\" (got: $ROM_BUILD_FLASHABLE_ZIP)"
    exit 1
fi

ROM_ENABLE_AVB="${ROM_ENABLE_AVB:-false}"
if [[ "$ROM_ENABLE_AVB" != "true" ]] && \
        [[ "$ROM_ENABLE_AVB" != "false" ]]; then
    LOGE "ROM_ENABLE_AVB must be \"true\" or \"false\" (got: $ROM_ENABLE_AVB)"
    exit 1
fi

ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS="${ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS:-true}"
if [[ "$ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ]] && \
        [[ "$ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "false" ]]; then
    LOGE "ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS must be \"true\" or \"false\" (got: $ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS)"
    exit 1
fi

ROM_AVB_VBMETA_ONLY="${ROM_AVB_VBMETA_ONLY:-false}"
if [[ "$ROM_AVB_VBMETA_ONLY" != "true" ]] && \
        [[ "$ROM_AVB_VBMETA_ONLY" != "false" ]]; then
    LOGE "ROM_AVB_VBMETA_ONLY must be \"true\" or \"false\" (got: $ROM_AVB_VBMETA_ONLY)"
    exit 1
fi
if [[ "$ROM_AVB_VBMETA_ONLY" == "true" ]] && [[ "$ROM_ENABLE_AVB" != "true" ]]; then
    LOGE "ROM_AVB_VBMETA_ONLY requires ROM_ENABLE_AVB=\"true\""
    exit 1
fi

TARGET_KEEP_ORIGINAL_SIGN="${TARGET_KEEP_ORIGINAL_SIGN:-$(GET_DEFAULT_KEEP_ORIGINAL_SIGN)}"
if [[ "$TARGET_KEEP_ORIGINAL_SIGN" != "true" ]] && \
        [[ "$TARGET_KEEP_ORIGINAL_SIGN" != "false" ]]; then
    LOGE "TARGET_KEEP_ORIGINAL_SIGN must be \"true\" or \"false\" (got: $TARGET_KEEP_ORIGINAL_SIGN)"
    exit 1
fi

if [[ "$ROM_ENABLE_AVB" != "true" ]] && \
        [[ "$TARGET_KEEP_ORIGINAL_SIGN" != "true" ]]; then
    LOGE "Modified kernel/image builds must either keep original signatures or use ROM_ENABLE_AVB=\"true\" for the official AVB re-sign flow."
    exit 1
fi

if [ ! -f "$SRC_DIR/unica/configs/$SINGLE_SYSTEM_IMAGE.sh" ]; then
    LOGE "\"$SINGLE_SYSTEM_IMAGE\" is not a valid system image"
    exit 1
else
    source "$SRC_DIR/unica/configs/$SINGLE_SYSTEM_IMAGE.sh" || exit 1
fi

FINAL_TARGET_OS_FILE_SYSTEM="$TARGET_OS_FILE_SYSTEM"
if [[ "$FORCE_EXT4_IMAGES" == "true" ]] && [[ "$FINAL_TARGET_OS_FILE_SYSTEM" == "erofs" ]]; then
    FINAL_TARGET_OS_FILE_SYSTEM="ext4"
fi
if [ ! "$FINAL_TARGET_OS_FILE_SYSTEM" ]; then
    LOGE "TARGET_OS_FILE_SYSTEM is empty"
    exit 1
elif [[ "$FINAL_TARGET_OS_FILE_SYSTEM" != "ext4" ]] && \
        [[ "$FINAL_TARGET_OS_FILE_SYSTEM" != "f2fs" ]] && \
        [[ "$FINAL_TARGET_OS_FILE_SYSTEM" != "erofs" ]]; then
    LOGE "Unsupported TARGET_OS_FILE_SYSTEM: $FINAL_TARGET_OS_FILE_SYSTEM"
    exit 1
fi

TARGET_BUILD_FLASHABLE_ZIP="$ROM_BUILD_FLASHABLE_ZIP"
TARGET_BUILD_ODIN_PACKAGE="true"
TARGET_ODIN_USE_SUPER_IMAGE="$(GET_DEFAULT_ODIN_SUPER_IMAGE)"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

if [ -f "$OUT_DIR/config.sh" ]; then
    LOGW "config.sh already exists. Regenerating"
    rm -f "$OUT_DIR/config.sh"
fi

{
    echo "# Automatically generated by scripts/internal/gen_config_file.sh"
    GET_BUILD_VAR "DEBUG" "false"
    echo "ROM_IS_OFFICIAL=\"$(GET_DEFAULT_ROM_IS_OFFICIAL)\""
    GET_BUILD_VAR "ROM_VERSION"
    GET_BUILD_VAR "ROM_CODENAME"
    GET_BUILD_VAR "ROM_DISPLAY_NAME"
    GET_BUILD_VAR "ROM_TYPE" "default"
    GET_BUILD_VAR "ROM_DEBLOAT_LEVEL" "default"
    GET_BUILD_VAR "ROM_BUILD_TIMESTAMP" "$(date +%s)"
    GET_BUILD_VAR "SOURCE_FIRMWARE"
    if [ "${#SOURCE_EXTRA_FIRMWARES[@]}" -ge 1 ]; then
        echo "SOURCE_EXTRA_FIRMWARES=\"$(IFS=":"; printf '%s' "${SOURCE_EXTRA_FIRMWARES[*]}")\""
    else
        echo "SOURCE_EXTRA_FIRMWARES=\"\""
    fi
    GET_BUILD_VAR "SOURCE_API_LEVEL"
    GET_BUILD_VAR "SOURCE_PRODUCT_FIRST_API_LEVEL"
    GET_BUILD_VAR "SOURCE_VNDK_VERSION"
    GET_BUILD_VAR "TARGET_NAME"
    GET_BUILD_VAR "SOURCE_CODENAME"
    GET_BUILD_VAR "TARGET_CODENAME"
    GET_BUILD_VAR "TARGET_PLATFORM"
    if [ "${#TARGET_ASSERT_MODEL[@]}" -ge 1 ]; then
        echo "TARGET_ASSERT_MODEL=\"$(IFS=":"; printf '%s' "${TARGET_ASSERT_MODEL[*]}")\""
    else
        echo "TARGET_ASSERT_MODEL=\"\""
    fi
    GET_BUILD_VAR "TARGET_FIRMWARE"
    if [ "${#TARGET_EXTRA_FIRMWARES[@]}" -ge 1 ]; then
        echo "TARGET_EXTRA_FIRMWARES=\"$(IFS=":"; printf '%s' "${TARGET_EXTRA_FIRMWARES[*]}")\""
    else
        echo "TARGET_EXTRA_FIRMWARES=\"\""
    fi
    GET_BUILD_VAR "TARGET_API_LEVEL"
    GET_BUILD_VAR "TARGET_PRODUCT_FIRST_API_LEVEL"
    GET_BUILD_VAR "TARGET_VNDK_VERSION"
    GET_BUILD_VAR "TARGET_SINGLE_SYSTEM_IMAGE"
    GET_BUILD_VAR "FORCE_EXT4_IMAGES" "false"
    echo "TARGET_OS_FILE_SYSTEM=\"$FINAL_TARGET_OS_FILE_SYSTEM\""
    GET_BUILD_VAR "TARGET_BOOT_DEVICE_PATH" "/dev/block/by-name"
    GET_BUILD_VAR "TARGET_KEEP_ORIGINAL_SIGN" "$(GET_DEFAULT_KEEP_ORIGINAL_SIGN)"
    GET_BUILD_VAR "TARGET_ENABLE_ENCRYPTION" "false"
    GET_BUILD_VAR "TARGET_BUILD_FLASHABLE_ZIP" "$TARGET_BUILD_FLASHABLE_ZIP"
    GET_BUILD_VAR "TARGET_BUILD_ODIN_PACKAGE" "$TARGET_BUILD_ODIN_PACKAGE"
    GET_BUILD_VAR "TARGET_ODIN_USE_SUPER_IMAGE" "$TARGET_ODIN_USE_SUPER_IMAGE"
    GET_BUILD_VAR "TARGET_ODIN_EXTRA_PARTITIONS" "$(GET_DEFAULT_ODIN_EXTRA_PARTITIONS)"
    GET_BUILD_VAR "TARGET_ODIN_EXTRA_IMAGE_MAP" "$(GET_DEFAULT_AVB_FIRMWARE_IMAGE_MAP)"
    GET_BUILD_VAR "TARGET_ROM_ZIP_COMPRESSION_LEVEL" "5"
    GET_BUILD_VAR "TARGET_BROTLI_QUALITY" "4"
    GET_BUILD_VAR "TARGET_ENABLE_CUSTOM_AVB" "$ROM_ENABLE_AVB"
    GET_BUILD_VAR "TARGET_PLATFORM_KEY_SOURCE_PEM" "$(GET_DEFAULT_PLATFORM_KEY_SOURCE_PEM)"
    GET_BUILD_VAR "TARGET_PLATFORM_CERT_X509_PATH" "$(GET_DEFAULT_PLATFORM_CERT_X509_PATH)"
    GET_BUILD_VAR "TARGET_PLATFORM_CERT_PK8_PATH" "$(GET_DEFAULT_PLATFORM_CERT_PK8_PATH)"
    GET_BUILD_VAR "TARGET_PLATFORM_CERT_SUBJECT" "/CN=CreckerROM Platform/"
    GET_BUILD_VAR "TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT" "true"
    GET_BUILD_VAR "TARGET_AVB_KEY_PATH" "$(GET_DEFAULT_AVB_KEY_PATH)"
    GET_BUILD_VAR "TARGET_AVB_ALGORITHM" "$(GET_DEFAULT_AVB_ALGORITHM)"
    GET_BUILD_VAR "TARGET_AVBTOOL_PATH" "$SRC_DIR/platform_external_avb-master/avbtool.py"
    GET_BUILD_VAR "TARGET_AVBTOOL_PYTHON" "none"
    GET_BUILD_VAR "TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" "$(GET_DEFAULT_AVB_INCLUDE_PARTITION_DESCRIPTORS)"
    GET_BUILD_VAR "TARGET_AVB_VBMETA_ONLY" "$(GET_DEFAULT_AVB_VBMETA_ONLY)"
    GET_BUILD_VAR "TARGET_AVB_HASH_PARTITIONS" ""
    GET_BUILD_VAR "TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS" "$(GET_DEFAULT_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS)"
    GET_BUILD_VAR "TARGET_AVB_FIRMWARE_IMAGE_MAP" "$(GET_DEFAULT_AVB_FIRMWARE_IMAGE_MAP)"
    GET_BUILD_VAR "TARGET_AVB_HASHTREE_PARTITIONS" ""
    GET_BUILD_VAR "TARGET_AVB_CHAIN_PARTITIONS" ""
    GET_BUILD_VAR "TARGET_AVB_ORIGINAL_VBMETA_PATH" "$OUT_DIR/fw/$TARGET_FIRMWARE_PATH/avb/vbmeta.img"
    GET_BUILD_VAR "TARGET_AVB_FLASH_VBMETA_IN_ZIP" "true"
    GET_BUILD_VAR "TARGET_AVB_ALLOW_HASHTREE_FALLBACK" "false"
    GET_BUILD_VAR "TARGET_AVB_CREATE_IMAGE_PACK_ZIP" "false"
    GET_BUILD_VAR "TARGET_AVB_IMAGE_PACK_COMPRESSION_LEVEL" "1"
    GET_BUILD_VAR "TARGET_AVB_ROLLBACK_INDEX" "0"
    GET_BUILD_VAR "TARGET_AVB_ROLLBACK_INDEX_LOCATION" "0"
    GET_BUILD_VAR "TARGET_AVB_HASH_ALGORITHM" "sha256"
    GET_BUILD_VAR "TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS" ""
    EMIT_EXTRA_AVB_VARS
    GET_BUILD_VAR "TARGET_BOOT_PARTITION_SIZE" "none"
    GET_BUILD_VAR "TARGET_DTBO_PARTITION_SIZE" "none"
    GET_BUILD_VAR "TARGET_INIT_BOOT_PARTITION_SIZE" "none"
    GET_BUILD_VAR "TARGET_VENDOR_BOOT_PARTITION_SIZE" "none"
    GET_BUILD_VAR "TARGET_REQUIRES_SPECIFIC_FIRMWARE" "false"
    GET_BUILD_VAR "TARGET_SUPPORTED_FIRMWARES" "none"
    GET_BUILD_VAR "TARGET_SUPER_PARTITION_SIZE"
    GET_BUILD_VAR "SOURCE_SUPER_GROUP_NAME"
    GET_BUILD_VAR "TARGET_SUPER_GROUP_NAME" "$SOURCE_SUPER_GROUP_NAME"
    GET_BUILD_VAR "TARGET_SUPER_GROUP_SIZE"
    GET_BUILD_VAR "SOURCE_HAS_SYSTEM_EXT"
    GET_BUILD_VAR "TARGET_HAS_SYSTEM_EXT"
    GET_BUILD_VAR "SOURCE_AUDIO_SUPPORT_ACH_RINGTONE"
    GET_BUILD_VAR "TARGET_AUDIO_SUPPORT_ACH_RINGTONE"
    GET_BUILD_VAR "SOURCE_AUDIO_SUPPORT_VIRTUAL_VIBRATION"
    GET_BUILD_VAR "TARGET_AUDIO_SUPPORT_VIRTUAL_VIBRATION"
    GET_BUILD_VAR "SOURCE_AUTO_BRIGHTNESS_TYPE"
    GET_BUILD_VAR "TARGET_AUTO_BRIGHTNESS_TYPE"
    GET_BUILD_VAR "SOURCE_DVFS_CONFIG_NAME"
    GET_BUILD_VAR "TARGET_DVFS_CONFIG_NAME"
    GET_BUILD_VAR "SOURCE_NFC_CHIP_VENDOR" "none"
    GET_BUILD_VAR "TARGET_NFC_CHIP_VENDOR" "none"
    GET_BUILD_VAR "SOURCE_FP_SENSOR_CONFIG"
    GET_BUILD_VAR "TARGET_FP_SENSOR_CONFIG"
    GET_BUILD_VAR "SOURCE_HAS_HW_MDNIE"
    GET_BUILD_VAR "TARGET_HAS_HW_MDNIE"
    GET_BUILD_VAR "SOURCE_HAS_MASS_CAMERA_APP"
    GET_BUILD_VAR "TARGET_HAS_MASS_CAMERA_APP"
    GET_BUILD_VAR "SOURCE_HAS_QHD_DISPLAY"
    GET_BUILD_VAR "TARGET_HAS_QHD_DISPLAY"
    GET_BUILD_VAR "SOURCE_HFR_MODE"
    GET_BUILD_VAR "TARGET_HFR_MODE"
    GET_BUILD_VAR "SOURCE_HFR_SUPPORTED_REFRESH_RATE" "none"
    GET_BUILD_VAR "TARGET_HFR_SUPPORTED_REFRESH_RATE" "none"
    GET_BUILD_VAR "SOURCE_HFR_DEFAULT_REFRESH_RATE" "none"
    GET_BUILD_VAR "TARGET_HFR_DEFAULT_REFRESH_RATE" "none"
    GET_BUILD_VAR "SOURCE_HFR_SEAMLESS_BRT" "none"
    GET_BUILD_VAR "TARGET_HFR_SEAMLESS_BRT" "none"
    GET_BUILD_VAR "SOURCE_HFR_SEAMLESS_LUX" "none"
    GET_BUILD_VAR "TARGET_HFR_SEAMLESS_LUX" "none"
    GET_BUILD_VAR "SOURCE_IS_ESIM_SUPPORTED"
    GET_BUILD_VAR "TARGET_IS_ESIM_SUPPORTED"
    GET_BUILD_VAR "SOURCE_MDNIE_SUPPORTED_MODES"
    GET_BUILD_VAR "TARGET_MDNIE_SUPPORTED_MODES"
    GET_BUILD_VAR "SOURCE_MDNIE_WEAKNESS_SOLUTION_FUNCTION"
    GET_BUILD_VAR "TARGET_MDNIE_WEAKNESS_SOLUTION_FUNCTION"
    GET_BUILD_VAR "SOURCE_MDNIE_SUPPORT_HDR_EFFECT" "$(test "$((SOURCE_MDNIE_SUPPORTED_MODES & 4))" != "0" && echo "true" || echo "false")"
    GET_BUILD_VAR "TARGET_MDNIE_SUPPORT_HDR_EFFECT" "$(test "$((TARGET_MDNIE_SUPPORTED_MODES & 4))" != "0" && echo "true" || echo "false")"
    GET_BUILD_VAR "SOURCE_DISPLAY_CUTOUT_TYPE" "none"
    GET_BUILD_VAR "TARGET_DISPLAY_CUTOUT_TYPE" "none"
    GET_BUILD_VAR "SOURCE_SUPPORT_WIFI_7" "false"
    GET_BUILD_VAR "TARGET_SUPPORT_WIFI_7" "false"
    GET_BUILD_VAR "SOURCE_SUPPORT_HOTSPOT_DUALAP" "false"
    GET_BUILD_VAR "TARGET_SUPPORT_HOTSPOT_DUALAP" "false"
    GET_BUILD_VAR "SOURCE_SUPPORT_HOTSPOT_WPA3" "false"
    GET_BUILD_VAR "TARGET_SUPPORT_HOTSPOT_WPA3" "false"
    GET_BUILD_VAR "SOURCE_SUPPORT_HOTSPOT_6GHZ" "false"
    GET_BUILD_VAR "TARGET_SUPPORT_HOTSPOT_6GHZ" "false"
    GET_BUILD_VAR "SOURCE_SUPPORT_HOTSPOT_WIFI_6" "false"
    GET_BUILD_VAR "TARGET_SUPPORT_HOTSPOT_WIFI_6" "false"
    GET_BUILD_VAR "SOURCE_SUPPORT_HOTSPOT_ENHANCED_OPEN" "false"
    GET_BUILD_VAR "TARGET_SUPPORT_HOTSPOT_ENHANCED_OPEN" "false"
} > "$OUT_DIR/config.sh"

unset SINGLE_SYSTEM_IMAGE

exit 0
