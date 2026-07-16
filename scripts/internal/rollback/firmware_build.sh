ROLLBACK_FIRMWARE="${TARGET_ROLLBACK_FIRMWARE:-}"
ROLLBACK_INDEX="${TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX:-${TARGET_AVB_ROLLBACK_INDEX:-}}"
[ -n "$ROLLBACK_INDEX" ] && [ "$ROLLBACK_INDEX" != "none" ] || {
    # The rollback value is tied to the selected BL1 model metadata; do not
    # guess a default that the boot chain may reject.
    LOGE "Model-specific rollback index is missing from the generated config"
    exit 1
}
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
# These images are treated as opaque stock payloads until the signing phases;
# rollback mode only swaps selected boot/recovery/bootloader pieces.
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

# Export exact stock sizes for every partition that AVB will touch; rollback
# cannot rely on target config from the normal ROM build.
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

# Reuse the old firmware vbmeta images as the layout source, then re-sign the
# replacement images into that same descriptor topology.
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
# Verify logical-partition metadata before adding the Samsung download
# signature, so signing errors are not mixed with layout drift.
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
