#!/usr/bin/env bash
#
# Samsung secure-boot signing hook for Exynos9830/Exynos990 targets.
#

# [
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

TARGET_ENABLE_SAMSUNG_SIGNING="${TARGET_ENABLE_SAMSUNG_SIGNING:-false}"
TARGET_SAMSUNG_SIGN_BOOTLOADER="${TARGET_SAMSUNG_SIGN_BOOTLOADER:-$TARGET_ENABLE_SAMSUNG_SIGNING}"
TARGET_SAMSUNG_SIGNING_SOC="${TARGET_SAMSUNG_SIGNING_SOC:-exynos990}"
TARGET_SAMSUNG_SIGNING_KEY_DIR="${TARGET_SAMSUNG_SIGNING_KEY_DIR:-$SRC_DIR/security/samsung/exynos9830_crecker}"
TARGET_SAMSUNG_LK_PATCH_TABLE="${TARGET_SAMSUNG_LK_PATCH_TABLE:-$SRC_DIR/security/samsung/patches/lk_985_selected_patches.tsv}"
TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX="${TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX:-23}"
TARGET_SAMSUNG_AVBTOOL_PATH="${TARGET_SAMSUNG_AVBTOOL_PATH:-${TARGET_AVBTOOL_PATH:-$SRC_DIR/platform_external_avb-master/avbtool.py}}"
TARGET_SAMSUNG_AVB_KEY_PATH="${TARGET_SAMSUNG_AVB_KEY_PATH:-${TARGET_AVB_KEY_PATH:-$SRC_DIR/security/avb/creckerrom_avb_private.pem}}"
TARGET_SAMSUNG_AVB_ALGORITHM="${TARGET_SAMSUNG_AVB_ALGORITHM:-${TARGET_AVB_ALGORITHM:-SHA256_RSA4096}}"
TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY="${TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY:-true}"
TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH="${TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH:-none}"
TARGET_SAMSUNG_BL1_MACHINE_ID="${TARGET_SAMSUNG_BL1_MACHINE_ID:-0x9830}"
TARGET_SAMSUNG_BL1_MODEL_ID="${TARGET_SAMSUNG_BL1_MODEL_ID:-0x142}"
TARGET_SAMSUNG_BL1_EVT="${TARGET_SAMSUNG_BL1_EVT:-11}"
TARGET_SAMSUNG_FWBL1_SIZE="${TARGET_SAMSUNG_FWBL1_SIZE:-0x3000}"

SIGNED_BOOTLOADER_DIR="${TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR:-$OUT_DIR/target/$TARGET_CODENAME/signed_bootloader}"
WORK_BOOTLOADER_DIR="${TARGET_SAMSUNG_BOOTLOADER_WORK_DIR:-$OUT_DIR/target/$TARGET_CODENAME/samsung_bootchain_work}"
BOOTLOADER_FILES="sboot.bin ldfw.img tzsw.img keystorage.bin harx.bin ssp.img tzar.img uh.bin vbmeta_samsung.img up_param.bin"
TARGET_FIRMWARE_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_CSC="$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_PATH="${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}"
# ]

FIND_TARGET_BL_TAR()
{
    local MODEL_ALT="${MODEL#SM-}"
    local PATTERN
    local TAR_FILE=""

    for PATTERN in "BL_${MODEL}*.md5" "BL_${MODEL_ALT}*.md5" "BL_*.md5" "BL_${MODEL}*.tar" "BL_${MODEL_ALT}*.tar" "BL_*.tar"; do
        TAR_FILE="$(find "$ODIN_DIR/${MODEL}_${CSC}" -maxdepth 1 -name "$PATTERN" | sort -r | head -n 1)"
        [ -n "$TAR_FILE" ] && break
    done

    [ -n "$TAR_FILE" ] && echo "$TAR_FILE"
}

EXTRACT_BOOTLOADER_FILE_FROM_TAR_IF_PRESENT()
{
    local BL_TAR="$1"
    local FILE="$2"
    local TARGET_DIR="$FW_DIR/${MODEL}_${CSC}/bootloader"

    [ -f "$TARGET_DIR/$FILE" ] && return 0

    if ! FILE_EXISTS_IN_TAR "$BL_TAR" "$FILE" && ! FILE_EXISTS_IN_TAR "$BL_TAR" "$FILE.lz4" && ! FILE_EXISTS_IN_TAR "$BL_TAR" "$FILE.ext4"; then
        return 0
    fi

    EXTRACT_FILE_FROM_TAR "$BL_TAR" "$FILE" || exit 1
    if [ -f "$FW_DIR/${MODEL}_${CSC}/$FILE" ]; then
        mkdir -p "$TARGET_DIR"
        mv -f "$FW_DIR/${MODEL}_${CSC}/$FILE" "$TARGET_DIR/$FILE"
    fi
}

ENSURE_BOOTLOADER_BINARIES_EXTRACTED()
{
    local BL_TAR=""
    local FILE

    MODEL="$TARGET_FIRMWARE_MODEL"
    CSC="$TARGET_FIRMWARE_CSC"

    [ -n "$MODEL" ] && [ -n "$CSC" ] || {
        LOGE "Unable to parse TARGET_FIRMWARE=$TARGET_FIRMWARE"
        exit 1
    }

    if [ -f "$FW_DIR/${MODEL}_${CSC}/bootloader/sboot.bin" ]; then
        return 0
    fi

    BL_TAR="$(FIND_TARGET_BL_TAR || true)"
    [ -n "$BL_TAR" ] && [ -f "$BL_TAR" ] || {
        LOGE "No BL tar found for $MODEL/$CSC under $ODIN_DIR/${MODEL}_${CSC}"
        exit 1
    }

    mkdir -p "$FW_DIR/${MODEL}_${CSC}/bootloader"
    for FILE in $BOOTLOADER_FILES; do
        EXTRACT_BOOTLOADER_FILE_FROM_TAR_IF_PRESENT "$BL_TAR" "$FILE"
    done
}

VALIDATE_BOOL()
{
    local NAME="$1"
    local VALUE="$2"

    if [ "$VALUE" != "true" ] && [ "$VALUE" != "false" ]; then
        LOGE "$NAME must be true or false (got: $VALUE)"
        exit 1
    fi
}

VALIDATE_BOOL "TARGET_ENABLE_SAMSUNG_SIGNING" "$TARGET_ENABLE_SAMSUNG_SIGNING"
VALIDATE_BOOL "TARGET_SAMSUNG_SIGN_BOOTLOADER" "$TARGET_SAMSUNG_SIGN_BOOTLOADER"
VALIDATE_BOOL "TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY" "$TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY"

$TARGET_ENABLE_SAMSUNG_SIGNING || exit 0
$TARGET_SAMSUNG_SIGN_BOOTLOADER || exit 0

if [ "$TARGET_PLATFORM" != "exynos990" ]; then
    LOGW "Samsung Exynos9830 signing is only enabled for TARGET_PLATFORM=exynos990; skipping $TARGET_PLATFORM"
    exit 0
fi

[ -n "$TARGET_FIRMWARE_MODEL" ] && [ -n "$TARGET_FIRMWARE_CSC" ] || {
    LOGE "Unable to parse TARGET_FIRMWARE=$TARGET_FIRMWARE"
    exit 1
}

ENSURE_BOOTLOADER_BINARIES_EXTRACTED

if [ ! -f "$FW_DIR/$TARGET_FIRMWARE_PATH/bootloader/sboot.bin" ]; then
    LOGE "Missing extracted stock sboot.bin: $FW_DIR/$TARGET_FIRMWARE_PATH/bootloader/sboot.bin"
    exit 1
fi

BOOTCHAIN_SIGN_ARGS=(
    "$SRC_DIR/scripts/samsung_signing/sign_bootloader_pack.py"
    --stock-dir "$FW_DIR/$TARGET_FIRMWARE_PATH/bootloader"
    --work-dir "$WORK_BOOTLOADER_DIR"
    --out-dir "$SIGNED_BOOTLOADER_DIR"
    --keys-dir "$TARGET_SAMSUNG_SIGNING_KEY_DIR"
    --patch-table "$TARGET_SAMSUNG_LK_PATCH_TABLE"
    --avbtool "$TARGET_SAMSUNG_AVBTOOL_PATH"
    --avb-key "$TARGET_SAMSUNG_AVB_KEY_PATH"
    --avb-algorithm "$TARGET_SAMSUNG_AVB_ALGORITHM"
    --soc "$TARGET_SAMSUNG_SIGNING_SOC"
    --rollback "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX"
    --fwbl1-size "$TARGET_SAMSUNG_FWBL1_SIZE"
    --machine-id "$TARGET_SAMSUNG_BL1_MACHINE_ID"
    --model-id "$TARGET_SAMSUNG_BL1_MODEL_ID"
    --evt "$TARGET_SAMSUNG_BL1_EVT"
)

if [ "$TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY" != "true" ]; then
    BOOTCHAIN_SIGN_ARGS+=(--no-update-keystorage-vbmeta-key)
fi

if [ -n "$TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH" ] && [ "$TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH" != "none" ]; then
    BOOTCHAIN_SIGN_ARGS+=(--keystorage-vbmeta-key "$TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH")
fi

python3 "${BOOTCHAIN_SIGN_ARGS[@]}" || exit 1

exit 0
