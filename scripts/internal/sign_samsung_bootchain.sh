#!/usr/bin/env bash
#
# Samsung secure-boot signing hook for Exynos9830/Exynos990 targets.
#

# [
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1
source "$SRC_DIR/scripts/samsung_signing/bl1_model_metadata.sh" || exit 1

TARGET_ENABLE_SAMSUNG_SIGNING="${TARGET_ENABLE_SAMSUNG_SIGNING:-false}"
TARGET_SAMSUNG_SIGN_BOOTLOADER="${TARGET_SAMSUNG_SIGN_BOOTLOADER:-$TARGET_ENABLE_SAMSUNG_SIGNING}"
TARGET_SAMSUNG_SIGNING_SOC="${TARGET_SAMSUNG_SIGNING_SOC:-exynos990}"
TARGET_SAMSUNG_SIGNING_KEY_DIR="${TARGET_SAMSUNG_SIGNING_KEY_DIR:-$SRC_DIR/security/samsung/exynos9830_crecker}"
TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX="${TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX:-none}"
TARGET_SAMSUNG_AVBTOOL_PATH="${TARGET_SAMSUNG_AVBTOOL_PATH:-${TARGET_AVBTOOL_PATH:-$SRC_DIR/external/android-tools/vendor/avb/avbtool.py}}"
TARGET_SAMSUNG_AVB_KEY_PATH="${TARGET_SAMSUNG_AVB_KEY_PATH:-${TARGET_AVB_KEY_PATH:-$SRC_DIR/security/avb/creckerrom_avb_private.pem}}"
TARGET_SAMSUNG_AVB_ALGORITHM="${TARGET_SAMSUNG_AVB_ALGORITHM:-${TARGET_AVB_ALGORITHM:-SHA256_RSA4096}}"
TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY="${TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY:-true}"
TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH="${TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH:-none}"
TARGET_SAMSUNG_TZAR_PATCH_FILE="${TARGET_SAMSUNG_TZAR_PATCH_FILE:-/sbin/root_task}"
TARGET_SAMSUNG_TZAR_PATCH_TABLE="${TARGET_SAMSUNG_TZAR_PATCH_TABLE:-$SRC_DIR/security/samsung/patches/tzar_root_task_selected_patches.tsv}"
TARGET_SAMSUNG_DECRYPTED_TZSW_PATH="${TARGET_SAMSUNG_DECRYPTED_TZSW_PATH:-none}"
TARGET_SAMSUNG_BL1_MACHINE_ID="${TARGET_SAMSUNG_BL1_MACHINE_ID:-0x9830}"
TARGET_SAMSUNG_BL1_MODEL="${TARGET_SAMSUNG_BL1_MODEL:-none}"
TARGET_SAMSUNG_BL1_MODEL_ID="${TARGET_SAMSUNG_BL1_MODEL_ID:-none}"
TARGET_SAMSUNG_BL1_EVT="${TARGET_SAMSUNG_BL1_EVT:-none}"
TARGET_SAMSUNG_FWBL1_SIZE="${TARGET_SAMSUNG_FWBL1_SIZE:-0x3000}"
TARGET_SAMSUNG_ENABLE_KVM="${TARGET_SAMSUNG_ENABLE_KVM:-false}"

SIGNED_BOOTLOADER_DIR="${TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR:-$OUT_DIR/target/$TARGET_CODENAME/signed_bootloader}"
WORK_BOOTLOADER_DIR="${TARGET_SAMSUNG_BOOTLOADER_WORK_DIR:-$OUT_DIR/target/$TARGET_CODENAME/samsung_bootchain_work}"
BOOTLOADER_FILES="sboot.bin ldfw.img tzsw.img keystorage.bin harx.bin ssp.img tzar.img uh.bin vbmeta_samsung.img up_param.bin"
TARGET_FIRMWARE_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_CSC="$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_PATH="${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}"
TARGET_LK_PATCH_MODEL_ID="${TARGET_SAMSUNG_BL1_MODEL#SM-}"
TARGET_LK_PATCH_MODEL_ID="$(tr "[:upper:]" "[:lower:]" <<< "$TARGET_LK_PATCH_MODEL_ID")"
# Patch selection follows the physical/BL1 model. Coupled LTE builds still use
# their 5G runtime SBoot, but their exact-model TSV rewrites LK's model IDs.
case "$TARGET_LK_PATCH_MODEL_ID" in
    "g780f"|"g980f"|"g981b"|"g985f"|"g986b"|"g988b"|\
    "n980f"|"n981b"|"n985f"|"n986b")
        ;;
    *)
        if [ -z "${TARGET_SAMSUNG_LK_PATCH_TABLE:-}" ]; then
            LOGE "No Samsung LK patch table for selected BL1 model: ${TARGET_SAMSUNG_BL1_MODEL:-<empty>}"
            exit 1
        fi
        TARGET_LK_PATCH_MODEL_ID=""
        ;;
esac
if [ -n "$TARGET_LK_PATCH_MODEL_ID" ]; then
    TARGET_SAMSUNG_LK_PATCH_TABLE="${TARGET_SAMSUNG_LK_PATCH_TABLE:-$SRC_DIR/security/samsung/patches/lk_${TARGET_LK_PATCH_MODEL_ID}_selected_patches.tsv}"
fi
if [ -z "${TARGET_SAMSUNG_LK_PATCH_TABLE:-}" ] || [ "$TARGET_SAMSUNG_LK_PATCH_TABLE" = "none" ]; then
    LOGE "TARGET_SAMSUNG_LK_PATCH_TABLE is required for Samsung bootloader signing"
    exit 1
fi
if [ ! -f "$TARGET_SAMSUNG_LK_PATCH_TABLE" ]; then
    LOGE "Missing Samsung LK patch table: $TARGET_SAMSUNG_LK_PATCH_TABLE"
    exit 1
fi
if [ "$TARGET_SAMSUNG_ENABLE_KVM" = "true" ]; then
    if [ -z "${TARGET_SAMSUNG_EL3_PATCH_TABLE:-}" ] || [ "$TARGET_SAMSUNG_EL3_PATCH_TABLE" = "none" ]; then
        TARGET_SAMSUNG_EL3_PATCH_TABLE="$SRC_DIR/security/samsung/patches/el3_mon_${TARGET_LK_PATCH_MODEL_ID}_kvm_patches.tsv"
    fi
    [ -f "$TARGET_SAMSUNG_EL3_PATCH_TABLE" ] || {
        LOGE "Missing Samsung EL3 monitor KVM patch table: $TARGET_SAMSUNG_EL3_PATCH_TABLE"
        exit 1
    }
fi
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
VALIDATE_BOOL "TARGET_SAMSUNG_ENABLE_KVM" "$TARGET_SAMSUNG_ENABLE_KVM"
$TARGET_ENABLE_SAMSUNG_SIGNING || exit 0
$TARGET_SAMSUNG_SIGN_BOOTLOADER || exit 0

if [ "$TARGET_PLATFORM" != "exynos990" ]; then
    LOGW "Samsung Exynos9830 signing is only enabled for TARGET_PLATFORM=exynos990; skipping $TARGET_PLATFORM"
    exit 0
fi

if ! SAMSUNG_BL1_METADATA="$(GET_SAMSUNG_BL1_MODEL_METADATA "$TARGET_SAMSUNG_BL1_MODEL")"; then
    LOGE "Unsupported Samsung BL1 model: $TARGET_SAMSUNG_BL1_MODEL"
    LOGE "Valid models: $(PRINT_SAMSUNG_BL1_SUPPORTED_MODELS)"
    exit 1
fi
read -r EXPECTED_SAMSUNG_BL1_MODEL_ID EXPECTED_SAMSUNG_BL1_EVT EXPECTED_SAMSUNG_ROLLBACK_INDEX <<< "$SAMSUNG_BL1_METADATA"
# BL1 model metadata binds the model id, EVT string, and rollback revision;
# mismatches here generally produce an unbootable signed boot chain.
if [ "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" = "none" ]; then
    TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX="$EXPECTED_SAMSUNG_ROLLBACK_INDEX"
fi
if [ "$TARGET_SAMSUNG_BL1_MODEL_ID" != "$EXPECTED_SAMSUNG_BL1_MODEL_ID" ]; then
    LOGE "TARGET_SAMSUNG_BL1_MODEL_ID=$TARGET_SAMSUNG_BL1_MODEL_ID does not match $TARGET_SAMSUNG_BL1_MODEL ($EXPECTED_SAMSUNG_BL1_MODEL_ID)"
    exit 1
fi
if [ "$TARGET_SAMSUNG_BL1_EVT" != "$EXPECTED_SAMSUNG_BL1_EVT" ]; then
    LOGE "TARGET_SAMSUNG_BL1_EVT=$TARGET_SAMSUNG_BL1_EVT does not match $TARGET_SAMSUNG_BL1_MODEL ($EXPECTED_SAMSUNG_BL1_EVT)"
    exit 1
fi
if [ "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" != "$EXPECTED_SAMSUNG_ROLLBACK_INDEX" ]; then
    LOGE "TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX=$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX does not match $TARGET_SAMSUNG_BL1_MODEL ($EXPECTED_SAMSUNG_ROLLBACK_INDEX)"
    exit 1
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
    --model "$TARGET_FIRMWARE_MODEL"
    --bl1-model "$TARGET_SAMSUNG_BL1_MODEL"
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

if [ "$TARGET_SAMSUNG_ENABLE_KVM" = "true" ]; then
    BOOTCHAIN_SIGN_ARGS+=(
        --kvm
        --el3-patch-table "$TARGET_SAMSUNG_EL3_PATCH_TABLE"
    )
fi

if [ "$TARGET_SAMSUNG_TZAR_PATCH_FILE" != "none" ] || [ "$TARGET_SAMSUNG_TZAR_PATCH_TABLE" != "none" ]; then
    if [ "$TARGET_SAMSUNG_TZAR_PATCH_FILE" = "none" ] || [ "$TARGET_SAMSUNG_TZAR_PATCH_TABLE" = "none" ]; then
        LOGE "TARGET_SAMSUNG_TZAR_PATCH_FILE and TARGET_SAMSUNG_TZAR_PATCH_TABLE must be set together"
        exit 1
    fi
    BOOTCHAIN_SIGN_ARGS+=(
        --tzar-patch-file "$TARGET_SAMSUNG_TZAR_PATCH_FILE"
        --tzar-patch-table "$TARGET_SAMSUNG_TZAR_PATCH_TABLE"
    )
fi

if [ "$TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY" != "true" ]; then
    BOOTCHAIN_SIGN_ARGS+=(--no-update-keystorage-vbmeta-key)
fi

if [ -n "$TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH" ] && [ "$TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH" != "none" ]; then
    BOOTCHAIN_SIGN_ARGS+=(--keystorage-vbmeta-key "$TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH")
fi

if [ -n "$TARGET_SAMSUNG_DECRYPTED_TZSW_PATH" ] && [ "$TARGET_SAMSUNG_DECRYPTED_TZSW_PATH" != "none" ]; then
    BOOTCHAIN_SIGN_ARGS+=(--decrypted-tzsw "$TARGET_SAMSUNG_DECRYPTED_TZSW_PATH")
fi

python3 "${BOOTCHAIN_SIGN_ARGS[@]}" || exit 1

exit 0
