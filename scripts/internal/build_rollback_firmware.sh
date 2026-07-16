#!/usr/bin/env bash
#
# Build an old Exynos990 firmware with current custom AVB/Samsung signatures.
# This path intentionally does not create or modify a normal ROM work directory.
#

set -e

source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

ROLLBACK_FIRMWARE="${TARGET_ROLLBACK_FIRMWARE:-}"
ROLLBACK_INDEX="${TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX:-23}"
OLD_ODIN_DIR="$ODIN_DIR/$ROLLBACK_FIRMWARE"
OLD_MODEL="${ROLLBACK_FIRMWARE%_*}"
OLD_CSC="${ROLLBACK_FIRMWARE##*_}"
NEW_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
NEW_CSC="$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
NEW_FIRMWARE_PATH="${NEW_MODEL}_${NEW_CSC}"
ROLLBACK_ROOT="$OUT_DIR/target/$TARGET_CODENAME/rollback/${ROLLBACK_FIRMWARE}"
SOURCE_DIR="$ROLLBACK_ROOT/source"
IMAGE_DIR="$ROLLBACK_ROOT/images"
EXTRA_DIR="$ROLLBACK_ROOT/extra"
SUPER_DIR="$ROLLBACK_ROOT/super"
OLD_BL_DIR="$ROLLBACK_ROOT/bootloader_old"
COMPOSITE_BL_DIR="$ROLLBACK_ROOT/bootloader_composite"
SIGNED_BL_DIR="$ROLLBACK_ROOT/bootloader_signed"
SIGNED_IMAGE_DIR="$ROLLBACK_ROOT/signed_images"
HEIMDALL_DIR="$OUT_DIR/rollback_${ROLLBACK_FIRMWARE}_${TARGET_CODENAME}-heimdall"
SUPER_LAYOUT="$SUPER_DIR/layout.json"
SUPER_REFERENCE="$SUPER_DIR/super.stock.sparse"
SUPER_RAW="$SUPER_DIR/super.stock.raw"
SUPER_UNSIGNED="$SUPER_DIR/super.unsigned.sparse"
SUPER_VERIFY_RAW="$SUPER_DIR/super.verify.raw"
SUPER_OUTPUT="$ROLLBACK_ROOT/super.img"

BOOTLOADER_FILES=(
    up_param.bin ldfw.img tzsw.img tzar.img keystorage.bin
    ssp.img uh.bin harx.bin vbmeta.img
)
FIND_PACKAGE_TAR()
{
    local DIRECTORY="$1"
    local PREFIX="$2"
    local RESULT=""

    RESULT="$(find "$DIRECTORY" -maxdepth 1 -type f \
        \( -name "${PREFIX}_*.tar.md5" -o -name "${PREFIX}_*.tar" -o -name "${PREFIX}_*.md5" \) \
        | sort -r | head -n 1)"
    [ -n "$RESULT" ] && echo "$RESULT"
}

EXTRACT_COMPONENT()
{
    local TAR_FILE="$1"
    local ENTRY="$2"
    local OUTPUT="$3"
    local REQUIRED="${4:-true}"
    local OUTPUT_DIR

    OUTPUT_DIR="$(dirname "$OUTPUT")"
    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT" "$OUTPUT.lz4" "$OUTPUT.ext4"

    if FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY"; then
        tar xf "$TAR_FILE" -O "$ENTRY" > "$OUTPUT"
    elif FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY.lz4"; then
        tar -xOf "$TAR_FILE" "$ENTRY.lz4" | lz4 -d - "$OUTPUT"
    elif FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY.ext4"; then
        tar xf "$TAR_FILE" -O "$ENTRY.ext4" > "$OUTPUT"
    elif $REQUIRED; then
        LOGE "$ENTRY was not found in $(basename "$TAR_FILE")"
        exit 1
    else
        return 1
    fi

    chmod u+w "$OUTPUT"
}

EXTRACT_PIT()
{
    local TAR_FILE="$1"
    local ENTRY

    ENTRY="$(tar tf "$TAR_FILE" | awk '/\.pit$/ { print; exit }')"
    [ -n "$ENTRY" ] || return 0
    tar xf "$TAR_FILE" -O "$ENTRY" > "$SOURCE_DIR/$(basename "$ENTRY")"
}

SET_PARTITION_SIZE()
{
    local PARTITION="$1"
    local IMAGE="$2"
    local SIZE
    local VAR_NAME

    SIZE="$(GET_IMAGE_SIZE "$IMAGE")"
    VAR_NAME="TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE"
    printf -v "$VAR_NAME" '%s' "$SIZE"
    export "$VAR_NAME"
}

SET_PARTITION_SIZE_VALUE()
{
    local PARTITION="$1"
    local SIZE="$2"
    local VAR_NAME

    VAR_NAME="TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE"
    printf -v "$VAR_NAME" '%s' "$SIZE"
    export "$VAR_NAME"
}

SAMSUNG_PRIVATE_KEY()
{
    case "$1" in
        2)
            echo "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage3_private.pem"
            ;;
        1)
            echo "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_ree_private.pem"
            ;;
        *)
            echo "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_tee_private.pem"
            ;;
    esac
}

GET_DOWNLOAD_KEY_TYPE()
{
    local IMAGE="$1"

    python3 - "$SRC_DIR" "$IMAGE" <<'PY'
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts/samsung_signing")
from download_signature_common import parse_download_signature_layout
try:
    print(parse_download_signature_layout(sys.argv[2]).key_type)
except ValueError:
    raise SystemExit(1)
PY
}

GET_STAGE2_KEY_TYPE()
{
    local IMAGE="$1"
    local STAGE="$2"

    python3 - "$SRC_DIR" "$IMAGE" "$STAGE" <<'PY'
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts/samsung_signing")
from stage2_common import normalize_stage, parse_stage2_footer, read_file, stage2_footer_candidate_sizes
stage = normalize_stage(sys.argv[3])
data = read_file(sys.argv[2])
sizes = stage2_footer_candidate_sizes(stage, data)
if not sizes:
    raise SystemExit(1)
print(parse_stage2_footer(data, sizes[0]).key_type)
PY
}

VERIFY_SAMSUNG_DOWNLOAD()
{
    python3 "$SRC_DIR/scripts/samsung_signing/download_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$1" \
        --tee-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_tee_pubkey.bin" \
        --ree-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_ree_pubkey.bin" \
        --stage3-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage3_pubkey.bin"
}

SIGN_DOWNLOAD_IMAGE()
{
    local IMAGE="$1"
    local REQUIRED="${2:-true}"
    local KEY_TYPE
    local PRIVATE_KEY
    local SIGNED_TMP="$IMAGE.signed.tmp"

    [ -f "$IMAGE" ] || return 0
    KEY_TYPE="$(GET_DOWNLOAD_KEY_TYPE "$IMAGE" || true)"
    if [ -z "$KEY_TYPE" ]; then
        if $REQUIRED; then
            LOGE "$(basename "$IMAGE") has no recognizable Samsung download signature"
            exit 1
        fi
        LOGW "$(basename "$IMAGE") has no recognizable Samsung download signature; keeping it unchanged"
        return 0
    fi

    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY "$KEY_TYPE")"
    LOG "- Samsung-signing $(basename "$IMAGE") download signature"
    rm -f "$SIGNED_TMP"
    python3 "$SRC_DIR/scripts/samsung_signing/download_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        -o "$SIGNED_TMP" \
        -k "$PRIVATE_KEY" \
        -r "$ROLLBACK_INDEX" \
        --key-type "$KEY_TYPE"
    mv -f "$SIGNED_TMP" "$IMAGE"
    VERIFY_SAMSUNG_DOWNLOAD "$IMAGE"
}

SIGN_STAGE2_IMAGE()
{
    local IMAGE="$1"
    local STAGE="$2"
    local REQUIRED="${3:-true}"
    local KEY_TYPE
    local PRIVATE_KEY

    [ -f "$IMAGE" ] || return 0
    KEY_TYPE="$(GET_STAGE2_KEY_TYPE "$IMAGE" "$STAGE" || true)"
    if [ -z "$KEY_TYPE" ]; then
        if $REQUIRED; then
            LOGE "$(basename "$IMAGE") has no recognizable Samsung Stage-2 footer"
            exit 1
        fi
        LOGW "$(basename "$IMAGE") has no recognizable Samsung Stage-2 footer; keeping it unchanged"
        return 0
    fi

    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY "$KEY_TYPE")"
    LOG "- Samsung-signing $(basename "$IMAGE") as $STAGE"
    python3 "$SRC_DIR/scripts/samsung_signing/stage2_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --stage "$STAGE" \
        -i "$IMAGE" \
        -o "$IMAGE" \
        -k "$PRIVATE_KEY" \
        -r "$ROLLBACK_INDEX" \
        --key-type "$KEY_TYPE"
    python3 "$SRC_DIR/scripts/samsung_signing/stage2_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --stage "$STAGE" \
        -i "$IMAGE" \
        --tee-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_tee_pubkey.bin" \
        --ree-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_ree_pubkey.bin" \
        --stage3-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage3_pubkey.bin"
}

SIGN_SUPER_IMAGE()
{
    local KEY_TYPE
    local PRIVATE_KEY

    KEY_TYPE="$(GET_DOWNLOAD_KEY_TYPE "$SUPER_REFERENCE")"
    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY "$KEY_TYPE")"
    python3 "$SRC_DIR/scripts/samsung_signing/download_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$SUPER_UNSIGNED" \
        -o "$SUPER_OUTPUT" \
        -k "$PRIVATE_KEY" \
        -r "$ROLLBACK_INDEX" \
        --key-type "$KEY_TYPE" \
        --super \
        --super-reference "$SUPER_REFERENCE"
    VERIFY_SAMSUNG_DOWNLOAD "$SUPER_OUTPUT"
}

COPY_IF_PRESENT()
{
    local SOURCE="$1"
    local DESTINATION="$2"

    [ -f "$SOURCE" ] || return 0
    cp -fa "$SOURCE" "$DESTINATION"
}

BUILD_BOOTLOADER()
{
    local FILE
    local ARGS=(
        "$SRC_DIR/scripts/samsung_signing/sign_bootloader_pack.py"
        --stock-dir "$COMPOSITE_BL_DIR"
        --work-dir "$ROLLBACK_ROOT/bootloader_work"
        --out-dir "$SIGNED_BL_DIR"
        --keys-dir "$TARGET_SAMSUNG_SIGNING_KEY_DIR"
        --model "$NEW_MODEL"
        --bl1-model "$TARGET_SAMSUNG_BL1_MODEL"
        --patch-table "$TARGET_SAMSUNG_LK_PATCH_TABLE"
        --avbtool "$TARGET_SAMSUNG_AVBTOOL_PATH"
        --avb-key "$TARGET_SAMSUNG_AVB_KEY_PATH"
        --avb-algorithm "$TARGET_SAMSUNG_AVB_ALGORITHM"
        --soc "$TARGET_SAMSUNG_SIGNING_SOC"
        --rollback "$ROLLBACK_INDEX"
        --fwbl1-size "$TARGET_SAMSUNG_FWBL1_SIZE"
        --machine-id "$TARGET_SAMSUNG_BL1_MACHINE_ID"
        --model-id "$TARGET_SAMSUNG_BL1_MODEL_ID"
        --evt "$TARGET_SAMSUNG_BL1_EVT"
    )

    mkdir -p "$COMPOSITE_BL_DIR"
    for FILE in "${BOOTLOADER_FILES[@]}"; do
        [ "$FILE" = "sboot.bin" ] && continue
        COPY_IF_PRESENT "$OLD_BL_DIR/$FILE" "$COMPOSITE_BL_DIR/$FILE"
    done
    cp -fa "$SOURCE_DIR/sboot.new.bin" "$COMPOSITE_BL_DIR/sboot.bin"

    if [ "${TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY:-true}" != "true" ]; then
        ARGS+=(--no-update-keystorage-vbmeta-key)
    fi
    if [ -n "${TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH:-}" ] && \
            [ "$TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH" != "none" ]; then
        ARGS+=(--keystorage-vbmeta-key "$TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH")
    fi

    python3 "${ARGS[@]}"

    cp -fa "$SIGNED_BL_DIR/sboot.bin" "$IMAGE_DIR/bootloader.img"
    cp -fa "$SIGNED_BL_DIR/harx.bin" "$IMAGE_DIR/harx.img"
    cp -fa "$SIGNED_BL_DIR/keystorage.bin" "$IMAGE_DIR/keystorage.img"
    cp -fa "$SIGNED_BL_DIR/ldfw.img" "$IMAGE_DIR/ldfw.img"
    cp -fa "$SIGNED_BL_DIR/tzsw.img" "$IMAGE_DIR/tzsw.img"

    SET_PARTITION_SIZE "bootloader" "$IMAGE_DIR/bootloader.img"
    SET_PARTITION_SIZE "harx" "$IMAGE_DIR/harx.img"
    SET_PARTITION_SIZE "keystorage" "$IMAGE_DIR/keystorage.img"
    SET_PARTITION_SIZE "ldfw" "$IMAGE_DIR/ldfw.img"
    SET_PARTITION_SIZE "tzsw" "$IMAGE_DIR/tzsw.img"
}

COPY_SIGNED_BOOTLOADER_AVB_IMAGES()
{
    cp -fa "$SIGNED_IMAGE_DIR/bootloader.img" "$SIGNED_BL_DIR/sboot.bin"
    cp -fa "$SIGNED_IMAGE_DIR/harx.img" "$SIGNED_BL_DIR/harx.bin"
    cp -fa "$SIGNED_IMAGE_DIR/keystorage.img" "$SIGNED_BL_DIR/keystorage.bin"
    cp -fa "$SIGNED_IMAGE_DIR/ldfw.img" "$SIGNED_BL_DIR/ldfw.img"
    cp -fa "$SIGNED_IMAGE_DIR/tzsw.img" "$SIGNED_BL_DIR/tzsw.img"
}

[ "$TARGET_BUILD_MODE" = "rollback" ] || {
    LOGE "build_rollback_firmware.sh requires TARGET_BUILD_MODE=rollback"
    exit 1
}
[ "$TARGET_PLATFORM" = "exynos990" ] || {
    LOGE "Rollback mode currently supports Exynos990 only"
    exit 1
}
[ -d "$OLD_ODIN_DIR" ] || {
    LOGE "Old firmware directory not found: $OLD_ODIN_DIR"
    exit 1
}
[ -d "$ODIN_DIR/$NEW_FIRMWARE_PATH" ] || {
    LOGE "Configured new firmware is not downloaded: $ODIN_DIR/$NEW_FIRMWARE_PATH"
    exit 1
}
case ":$TARGET_ASSERT_MODEL:" in
    *":$OLD_MODEL:"*)
        ;;
    *)
        LOGE "$OLD_MODEL is not valid for target $TARGET_CODENAME ($TARGET_ASSERT_MODEL)"
        exit 1
        ;;
esac
if [ "SM-$TARGET_SAMSUNG_BL1_MODEL" != "$OLD_MODEL" ]; then
    LOGE "--avb-model must match the old firmware device ($OLD_MODEL)"
    exit 1
fi

OLD_AP_TAR="$(FIND_PACKAGE_TAR "$OLD_ODIN_DIR" "AP")"
OLD_BL_TAR="$(FIND_PACKAGE_TAR "$OLD_ODIN_DIR" "BL")"
OLD_CSC_TAR="$(FIND_PACKAGE_TAR "$OLD_ODIN_DIR" "CSC")"
NEW_BL_TAR="$(FIND_PACKAGE_TAR "$ODIN_DIR/$NEW_FIRMWARE_PATH" "BL")"
for REQUIRED_TAR in "$OLD_AP_TAR" "$OLD_BL_TAR" "$OLD_CSC_TAR" "$NEW_BL_TAR"; do
    [ -f "$REQUIRED_TAR" ] || {
        LOGE "A required Odin archive is missing"
        exit 1
    }
done

rm -rf "$ROLLBACK_ROOT" "$HEIMDALL_DIR"
mkdir -p "$SOURCE_DIR" "$IMAGE_DIR" "$EXTRA_DIR" "$SUPER_DIR" "$OLD_BL_DIR"

LOG_STEP_IN "- Extracting opaque old firmware images"
EXTRACT_COMPONENT "$OLD_AP_TAR" "boot.img" "$IMAGE_DIR/boot.img"
EXTRACT_COMPONENT "$OLD_AP_TAR" "dtbo.img" "$IMAGE_DIR/dtbo.img"
EXTRACT_COMPONENT "$OLD_AP_TAR" "recovery.img" "$SOURCE_DIR/recovery.stock.img"
EXTRACT_COMPONENT "$OLD_AP_TAR" "vbmeta.img" "$SOURCE_DIR/vbmeta.stock.img"
EXTRACT_COMPONENT "$OLD_AP_TAR" "vbmeta_samsung.img" "$SOURCE_DIR/vbmeta_samsung.stock.img"
EXTRACT_COMPONENT "$OLD_AP_TAR" "misc.bin" "$EXTRA_DIR/misc.bin"
EXTRACT_COMPONENT "$OLD_AP_TAR" "super.img" "$SUPER_REFERENCE"

cp -fa "$SOURCE_DIR/vbmeta.stock.img" "$IMAGE_DIR/vbmeta.img"
cp -fa "$SOURCE_DIR/vbmeta_samsung.stock.img" "$IMAGE_DIR/vbmeta_samsung.img"

EXTRACT_COMPONENT "$OLD_CSC_TAR" "cache.img" "$EXTRA_DIR/cache.img"
EXTRACT_COMPONENT "$OLD_CSC_TAR" "omr.img" "$EXTRA_DIR/omr.img"
EXTRACT_COMPONENT "$OLD_CSC_TAR" "prism.img" "$IMAGE_DIR/prism.img"
EXTRACT_COMPONENT "$OLD_CSC_TAR" "optics.img" "$IMAGE_DIR/optics.img"
EXTRACT_PIT "$OLD_CSC_TAR"

for FILE in "${BOOTLOADER_FILES[@]}"; do
    EXTRACT_COMPONENT "$OLD_BL_TAR" "$FILE" "$OLD_BL_DIR/$FILE" "false" || true
done
EXTRACT_COMPONENT "$NEW_BL_TAR" "sboot.bin" "$SOURCE_DIR/sboot.new.bin"
LOG_STEP_OUT


LOG_STEP_IN "- Unpacking super logical partitions"
simg2img "$SUPER_REFERENCE" "$SUPER_RAW"
python3 "$SRC_DIR/scripts/internal/rollback_super.py" unpack \
    --super-image "$SUPER_RAW" \
    --output-dir "$IMAGE_DIR" \
    --layout "$SUPER_LAYOUT" \
    --lpdump "$TOOLS_DIR/bin/lpdump" \
    --lpunpack "$TOOLS_DIR/bin/lpunpack"
rm -f "$SUPER_RAW"
LOG_STEP_OUT

TARGET_SUPER_PARTITION_SIZE="$(python3 "$SRC_DIR/scripts/internal/rollback_super.py" values \
    --layout "$SUPER_LAYOUT" super-size)"
TARGET_SUPER_GROUP_SIZE="$(python3 "$SRC_DIR/scripts/internal/rollback_super.py" values \
    --layout "$SUPER_LAYOUT" group-size)"
export TARGET_SUPER_PARTITION_SIZE TARGET_SUPER_GROUP_SIZE

while IFS=$'\t' read -r PARTITION SIZE; do
    SET_PARTITION_SIZE_VALUE "$PARTITION" "$SIZE"
done < <(python3 "$SRC_DIR/scripts/internal/rollback_super.py" values \
    --layout "$SUPER_LAYOUT" partitions)

SET_PARTITION_SIZE "boot" "$IMAGE_DIR/boot.img"
SET_PARTITION_SIZE "dtbo" "$IMAGE_DIR/dtbo.img"
SET_PARTITION_SIZE "recovery" "$SOURCE_DIR/recovery.stock.img"
SET_PARTITION_SIZE "prism" "$IMAGE_DIR/prism.img"
SET_PARTITION_SIZE "optics" "$IMAGE_DIR/optics.img"

LOG_STEP_IN "- Replacing stock recovery with TWRP"
RECOVERY_ENTRY="$(unzip -Z1 "$TARGET_RECOVERY_IMAGE_PATH" | awk '/\.img$/ { print; exit }')"
[ -n "$RECOVERY_ENTRY" ] || {
    LOGE "No recovery image found in $TARGET_RECOVERY_IMAGE_PATH"
    exit 1
}
unzip -p "$TARGET_RECOVERY_IMAGE_PATH" "$RECOVERY_ENTRY" > "$IMAGE_DIR/recovery.img"
if [ "$(GET_IMAGE_SIZE "$IMAGE_DIR/recovery.img")" -gt "$TARGET_RECOVERY_PARTITION_SIZE" ]; then
    LOGE "TWRP is larger than the stock recovery partition"
    exit 1
fi
LOG_STEP_OUT

LOG_STEP_IN "- Building composite and re-signed bootloader"
BUILD_BOOTLOADER
LOG_STEP_OUT
TARGET_AVB_EXCLUDED_PARTITIONS=""
export TARGET_AVB_EXCLUDED_PARTITIONS

TARGET_FIRMWARE="$OLD_MODEL/$OLD_CSC/rollback"
TARGET_FIRMWARE_PATH="$ROLLBACK_FIRMWARE"
TARGET_AVB_ORIGINAL_VBMETA_PATH="$SOURCE_DIR/vbmeta.stock.img"
TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH="$SOURCE_DIR/vbmeta_samsung.stock.img"
TARGET_AVB_IMAGE_PACK_DIR="$SIGNED_IMAGE_DIR"
TARGET_AVB_IMAGE_PACK_ZIP="$ROLLBACK_ROOT/signed-images.zip"
TARGET_AVB_HASH_PARTITIONS=""
TARGET_AVB_HASHTREE_PARTITIONS=""
TARGET_AVB_CHAIN_PARTITIONS=""
TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS=""
TARGET_AVB_FIRMWARE_IMAGE_MAP=""
TARGET_AVB_VBMETA_SECURITY_PATCH_OVERRIDE="preserve"
TARGET_AVB_CREATE_IMAGE_PACK_ZIP="false"
TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES="true"
export TARGET_FIRMWARE TARGET_FIRMWARE_PATH TARGET_AVB_ORIGINAL_VBMETA_PATH
export TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH TARGET_AVB_IMAGE_PACK_DIR
export TARGET_AVB_IMAGE_PACK_ZIP TARGET_AVB_HASH_PARTITIONS TARGET_AVB_HASHTREE_PARTITIONS
export TARGET_AVB_CHAIN_PARTITIONS TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS
export TARGET_AVB_FIRMWARE_IMAGE_MAP TARGET_AVB_VBMETA_SECURITY_PATCH_OVERRIDE
export TARGET_AVB_CREATE_IMAGE_PACK_ZIP TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES

LOG_STEP_IN "- Samsung-signing AP images before AVB"
python3 "$SRC_DIR/scripts/samsung_signing/sign_ap_images.py" \
    --images-dir "$IMAGE_DIR" \
    --keys-dir "$TARGET_SAMSUNG_SIGNING_KEY_DIR" \
    --phase "before-avb" \
    --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
    --rollback "$ROLLBACK_INDEX"
LOG_STEP_OUT

LOG_STEP_IN "- Re-signing old firmware AVB images"
"$SRC_DIR/scripts/internal/sign_avb_images.sh" "$IMAGE_DIR"
LOG_STEP_OUT

LOG_STEP_IN "- Samsung-signing vbmeta images after AVB"
python3 "$SRC_DIR/scripts/samsung_signing/sign_ap_images.py" \
    --images-dir "$SIGNED_IMAGE_DIR" \
    --keys-dir "$TARGET_SAMSUNG_SIGNING_KEY_DIR" \
    --phase "after-avb" \
    --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
    --rollback "$ROLLBACK_INDEX"
LOG_STEP_OUT

COPY_SIGNED_BOOTLOADER_AVB_IMAGES

LOG_STEP_IN "- Samsung-signing opaque Odin components"
SIGN_DOWNLOAD_IMAGE "$SIGNED_IMAGE_DIR/prism.img"
SIGN_DOWNLOAD_IMAGE "$SIGNED_IMAGE_DIR/optics.img"
SIGN_DOWNLOAD_IMAGE "$EXTRA_DIR/cache.img"
SIGN_DOWNLOAD_IMAGE "$EXTRA_DIR/omr.img"
SIGN_STAGE2_IMAGE "$EXTRA_DIR/misc.bin" "misc"
LOG_STEP_OUT

LOG_STEP_IN "- Rebuilding and signing super.img"
python3 "$SRC_DIR/scripts/internal/rollback_super.py" build \
    --layout "$SUPER_LAYOUT" \
    --images-dir "$SIGNED_IMAGE_DIR" \
    --output "$SUPER_UNSIGNED" \
    --lpmake "$TOOLS_DIR/bin/lpmake"
simg2img "$SUPER_UNSIGNED" "$SUPER_VERIFY_RAW"
python3 "$SRC_DIR/scripts/internal/rollback_super.py" verify \
    --layout "$SUPER_LAYOUT" \
    --super-image "$SUPER_VERIFY_RAW" \
    --lpdump "$TOOLS_DIR/bin/lpdump"
rm -f "$SUPER_VERIFY_RAW"
SIGN_SUPER_IMAGE
rm -f "$SUPER_UNSIGNED" "$SUPER_REFERENCE"
LOG_STEP_OUT

LOG_STEP_IN "- Creating Heimdall rollback folder"
mkdir -p "$HEIMDALL_DIR"
cp -fa "$SUPER_OUTPUT" "$HEIMDALL_DIR/super.img"
for FILE in boot.img dtbo.img recovery.img vbmeta.img vbmeta_samsung.img prism.img optics.img; do
    COPY_IF_PRESENT "$SIGNED_IMAGE_DIR/$FILE" "$HEIMDALL_DIR/$FILE"
done
for FILE in misc.bin cache.img omr.img; do
    COPY_IF_PRESENT "$EXTRA_DIR/$FILE" "$HEIMDALL_DIR/$FILE"
done
for FILE in "$SIGNED_BL_DIR"/*.img "$SIGNED_BL_DIR"/*.bin; do
    [ -f "$FILE" ] || continue
    [ "$(basename "$FILE")" = "vbmeta_samsung.img" ] && continue
    cp -fa "$FILE" "$HEIMDALL_DIR/$(basename "$FILE")"
done

cp -fa "$SRC_DIR/prebuilts/extras/flash_rollback_heimdall.sh" "$HEIMDALL_DIR/flash_all.sh"
chmod 0755 "$HEIMDALL_DIR/flash_all.sh"
(
    cd "$HEIMDALL_DIR"
    find . -type f ! -name sha256sums.txt -print0 | sort -z | xargs -0 sha256sum > sha256sums.txt
)
LOG_STEP_OUT

LOG "- Rollback Heimdall folder: ${HEIMDALL_DIR//$SRC_DIR\//}"
exit 0
