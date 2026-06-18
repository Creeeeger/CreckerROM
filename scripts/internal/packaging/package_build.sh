SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_CSC="$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

TMP_DIR="$OUT_DIR/zip"
TARGET_BUILD_KERNEL_ONLY="${TARGET_BUILD_KERNEL_ONLY:-false}"
TARGET_BUILD_FLASHABLE_ZIP="${TARGET_BUILD_FLASHABLE_ZIP:-false}"
TARGET_BUILD_ODIN_PACKAGE="${TARGET_BUILD_ODIN_PACKAGE:-true}"
TARGET_BUILD_HEIMDALL_PACKAGE="${TARGET_BUILD_HEIMDALL_PACKAGE:-true}"
TARGET_ODIN_USE_SUPER_IMAGE="${TARGET_ODIN_USE_SUPER_IMAGE:-false}"
TARGET_ODIN_EXTRA_PARTITIONS="${TARGET_ODIN_EXTRA_PARTITIONS:-}"
TARGET_ODIN_EXTRA_IMAGE_MAP="${TARGET_ODIN_EXTRA_IMAGE_MAP:-${TARGET_AVB_FIRMWARE_IMAGE_MAP:-}}"
TARGET_BUILD_ODIN_CP_PACKAGE="${TARGET_BUILD_ODIN_CP_PACKAGE:-true}"
TARGET_BUILD_ODIN_CSC_PACKAGE="${TARGET_BUILD_ODIN_CSC_PACKAGE:-true}"
TARGET_RECOVERY_IMAGE_PATH="${TARGET_RECOVERY_IMAGE_PATH:-none}"
TARGET_ROM_ZIP_COMPRESSION_LEVEL="${TARGET_ROM_ZIP_COMPRESSION_LEVEL:-5}"
TARGET_BROTLI_QUALITY="${TARGET_BROTLI_QUALITY:-4}"
TARGET_ENABLE_CUSTOM_AVB="${TARGET_ENABLE_CUSTOM_AVB:-false}"
TARGET_AVB_LOW_SECURITY="${TARGET_AVB_LOW_SECURITY:-false}"
TARGET_ENABLE_SAMSUNG_SIGNING="${TARGET_ENABLE_SAMSUNG_SIGNING:-false}"
TARGET_SAMSUNG_SIGN_AP_IMAGES="${TARGET_SAMSUNG_SIGN_AP_IMAGES:-$TARGET_ENABLE_SAMSUNG_SIGNING}"
TARGET_SAMSUNG_SIGN_SUPER_IMAGES="${TARGET_SAMSUNG_SIGN_SUPER_IMAGES:-$TARGET_SAMSUNG_SIGN_AP_IMAGES}"
TARGET_SAMSUNG_SIGN_BOOTLOADER="${TARGET_SAMSUNG_SIGN_BOOTLOADER:-$TARGET_ENABLE_SAMSUNG_SIGNING}"
TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE="${TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE:-$TARGET_SAMSUNG_SIGN_BOOTLOADER}"
TARGET_SAMSUNG_SIGNING_SOC="${TARGET_SAMSUNG_SIGNING_SOC:-exynos990}"
TARGET_SAMSUNG_SIGNING_KEY_DIR="${TARGET_SAMSUNG_SIGNING_KEY_DIR:-$SRC_DIR/security/samsung/exynos9830_crecker}"
TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX="${TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX:-${TARGET_AVB_ROLLBACK_INDEX:-0}}"
TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR="${TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR:-$OUT_DIR/target/$TARGET_CODENAME/signed_bootloader}"
TARGET_SAMSUNG_SUPER_REFERENCE_IMAGE="${TARGET_SAMSUNG_SUPER_REFERENCE_IMAGE:-auto}"
TARGET_SAMSUNG_DECRYPTED_TZSW_PATH="${TARGET_SAMSUNG_DECRYPTED_TZSW_PATH:-none}"

SOURCE_FINGERPRINT=""
TARGET_FINGERPRINT=""
if [ "$TARGET_BUILD_KERNEL_ONLY" != "true" ] && [ "$TARGET_BUILD_KERNEL_ONLY" != "false" ]; then
    LOGE "TARGET_BUILD_KERNEL_ONLY must be true or false (got: $TARGET_BUILD_KERNEL_ONLY)"
    exit 1
fi

if ! $TARGET_BUILD_KERNEL_ONLY; then
    SOURCE_FINGERPRINT="$(GET_PROP "$WORK_DIR/system/system/build.prop" "ro.system.build.fingerprint")"
    SOURCE_FINGERPRINT="${SOURCE_FINGERPRINT//$(GET_PROP "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/build.prop" "ro.build.product")/$(GET_PROP "$FW_DIR/$SOURCE_FIRMWARE_PATH/vendor/build.prop" "ro.product.vendor.device")}"
    TARGET_FINGERPRINT="$(GET_PROP "$WORK_DIR/vendor/build.prop" "ro.vendor.build.fingerprint")"
    TARGET_FINGERPRINT="${TARGET_FINGERPRINT//$(GET_PROP "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/build.prop" "ro.build.product")/$(GET_PROP "$FW_DIR/$TARGET_FIRMWARE_PATH/vendor/build.prop" "ro.product.vendor.device")}"
fi

if ! [[ "$TARGET_ROM_ZIP_COMPRESSION_LEVEL" =~ ^[0-9]$ ]]; then
    LOGW "Invalid TARGET_ROM_ZIP_COMPRESSION_LEVEL: $TARGET_ROM_ZIP_COMPRESSION_LEVEL (expected 0-9). Using 5."
    TARGET_ROM_ZIP_COMPRESSION_LEVEL="5"
fi

if ! [[ "$TARGET_BROTLI_QUALITY" =~ ^([0-9]|1[01])$ ]]; then
    LOGW "Invalid TARGET_BROTLI_QUALITY: $TARGET_BROTLI_QUALITY (expected 0-11). Using 4."
    TARGET_BROTLI_QUALITY="4"
fi

if [ "$TARGET_BUILD_HEIMDALL_PACKAGE" != "true" ] && [ "$TARGET_BUILD_HEIMDALL_PACKAGE" != "false" ]; then
    LOGW "Invalid TARGET_BUILD_HEIMDALL_PACKAGE: $TARGET_BUILD_HEIMDALL_PACKAGE (expected true|false). Using true."
    TARGET_BUILD_HEIMDALL_PACKAGE="true"
fi

if [ "$TARGET_AVB_LOW_SECURITY" != "true" ] && [ "$TARGET_AVB_LOW_SECURITY" != "false" ]; then
    LOGE "TARGET_AVB_LOW_SECURITY must be true or false (got: $TARGET_AVB_LOW_SECURITY)"
    exit 1
fi
if $TARGET_AVB_LOW_SECURITY && ! $TARGET_ENABLE_CUSTOM_AVB; then
    LOGE "TARGET_AVB_LOW_SECURITY=true requires TARGET_ENABLE_CUSTOM_AVB=true"
    exit 1
fi

if $TARGET_BUILD_KERNEL_ONLY; then
    TARGET_BUILD_FLASHABLE_ZIP="false"
    TARGET_BUILD_ODIN_PACKAGE="false"
    TARGET_BUILD_HEIMDALL_PACKAGE="true"

    if ! $TARGET_ENABLE_CUSTOM_AVB; then
        LOGE "Kernel-only builds require TARGET_ENABLE_CUSTOM_AVB=true"
        exit 1
    fi
    if [ "${TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS:-true}" != "false" ]; then
        LOGE "Kernel-only builds require TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS=false"
        exit 1
    fi
fi

ROM_DISPLAY_NAME="${ROM_DISPLAY_NAME:-CROM-S24FE-Official-${ROM_VERSION}}"

ZIP_FILE_SUFFIX="-sign.zip"
$DEBUG && ! $ROM_IS_OFFICIAL && ZIP_FILE_SUFFIX=".zip"

BUILD_DATE="$(date +%Y%m%d)"
FILE_NAME="${ROM_DISPLAY_NAME}_${BUILD_DATE}_${TARGET_CODENAME}${ZIP_FILE_SUFFIX}"
while [ -f "$OUT_DIR/$FILE_NAME" ]; do
    INCREMENTAL=$((INCREMENTAL + 1))
    FILE_NAME="${ROM_DISPLAY_NAME}_${BUILD_DATE}-${INCREMENTAL}_${TARGET_CODENAME}${ZIP_FILE_SUFFIX}"
done

export TARGET_AVB_IMAGE_PACK_DIR="$OUT_DIR/target/$TARGET_CODENAME/signed_images"
export TARGET_AVB_IMAGE_PACK_ZIP="$OUT_DIR/${FILE_NAME%.zip}-images.zip"
HEIMDALL_DIR="$OUT_DIR/${FILE_NAME%.zip}-heimdall"
ODIN_AP_DIR="$OUT_DIR/target/$TARGET_CODENAME/odin_ap"
ODIN_EXTRA_DIR="$OUT_DIR/target/$TARGET_CODENAME/odin_extra"
ODIN_EXTRA_AP_DIR="$ODIN_EXTRA_DIR/ap"
ODIN_EXTRA_CP_DIR="$ODIN_EXTRA_DIR/cp"
ODIN_EXTRA_CSC_DIR="$ODIN_EXTRA_DIR/csc"

ENSURE_SHARED_PLATFORM_SIGNING_CERTS || exit 1
PRIVATE_KEY_PATH="$(GET_PLATFORM_CERT_PK8_PATH)"
PUBLIC_KEY_PATH="$(GET_PLATFORM_CERT_X509_PATH)"

trap 'rm -rf "$TMP_DIR"' EXIT INT


# ]

[ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

if $TARGET_BUILD_KERNEL_ONLY; then
    COPY_KERNEL_TEST_IMAGES_TO_TMP
else
    mkdir -p "$TMP_DIR/META-INF/com/google/android"
    cp -a "$SRC_DIR/prebuilts/bootable/deprecated-ota/updater" "$TMP_DIR/META-INF/com/google/android/update-binary"
    mkdir -p "$TMP_DIR/scripts"
    cp -a "$SRC_DIR/prebuilts/extras/cleanup.sh" "$TMP_DIR/scripts/cleanup.sh"

    LOG_STEP_IN "- Building OS partitions"
    while IFS= read -r f; do
        PARTITION=$(basename "$f")
        IS_VALID_PARTITION_NAME "$PARTITION" || continue

        (
            LOG_STEP_IN "- Building $PARTITION.img"
            if [[ "$PARTITION" == "prism" || "$PARTITION" == "optics" ]]; then
                FILESYSTEM_TYPE="ext4"
            else
                FILESYSTEM_TYPE="$TARGET_OS_FILE_SYSTEM"
            fi
            "$SRC_DIR/scripts/build_fs_image.sh" "$FILESYSTEM_TYPE" \
                -o "$TMP_DIR/$PARTITION.img" -S \
                "$WORK_DIR/$PARTITION" "$WORK_DIR/configs/file_context-$PARTITION" "$WORK_DIR/configs/fs_config-$PARTITION" || exit 1
            LOG_STEP_OUT
        ) &
    done < <(find "$WORK_DIR" -maxdepth 1 -type d)
    LOG_STEP_OUT

    # shellcheck disable=SC2046
    wait $(jobs -p) || exit 1

    if [ -d "$WORK_DIR/kernel" ]; then
        while IFS= read -r f; do
            IMG="$(basename "$f")"
            LOG "- Copying $IMG"
            cp -fa "$WORK_DIR/kernel/$IMG" "$TMP_DIR/$IMG"
        done < <(find "$WORK_DIR/kernel" -maxdepth 1 -type f -name "*.img")
    fi

    if [ -f "$WORK_DIR/up_param.bin" ]; then
        LOG "- Copying up_param.bin"
        cp -fa "$WORK_DIR/up_param.bin" "$TMP_DIR/up_param.bin"
    fi

    COPY_TARGET_RECOVERY_IMAGE_TO_TMP
fi

if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_AP_IMAGES; then
    LOG_STEP_IN "- Samsung-signing AP images before AVB"
    # Stage-2 signatures cover image bytes. AVB footers are added after this so
    # AVB signs the final Samsung-signed payloads.
    RUN_SAMSUNG_AP_IMAGE_SIGNING "$TMP_DIR" "before-avb"
    LOG_STEP_OUT
fi

if ! $TARGET_BUILD_KERNEL_ONLY && $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_BOOTLOADER; then
    LOG_STEP_IN "- Samsung-signing bootloader"
    # Bootloader signing may produce firmware images whose AVB descriptors are
    # discovered by the later custom AVB pass.
    RUN_SAMSUNG_BOOTLOADER_SIGNING
    LOG_STEP_OUT
fi

if $TARGET_ENABLE_CUSTOM_AVB; then
    LOG_STEP_IN "- Preparing AVB images"
    "$SRC_DIR/scripts/internal/sign_avb_images.sh" "$TMP_DIR" || exit 1
    LOG_STEP_OUT
    if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_AP_IMAGES; then
        LOG_STEP_IN "- Samsung-signing vbmeta after AVB"
        # vbmeta is created by AVB signing, so Samsung-sign it after avbtool
        # finishes and copy the result back for package builders.
        RUN_SAMSUNG_AP_IMAGE_SIGNING "$TARGET_AVB_IMAGE_PACK_DIR" "after-avb"
        [ -f "$TARGET_AVB_IMAGE_PACK_DIR/vbmeta.img" ] && cp -fa "$TARGET_AVB_IMAGE_PACK_DIR/vbmeta.img" "$TMP_DIR/vbmeta.img"
        LOG_STEP_OUT
    fi
    COPY_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS_TO_TMP
fi

if ! $TARGET_BUILD_KERNEL_ONLY && { $TARGET_BUILD_ODIN_PACKAGE || $TARGET_BUILD_HEIMDALL_PACKAGE; }; then
    LOG_STEP_IN "- Preparing extra firmware images"
    PREPARE_ODIN_EXTRA_FIRMWARE_IMAGES
    LOG_STEP_OUT
fi

if $TARGET_BUILD_ODIN_PACKAGE; then
    if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE; then
        LOG_STEP_IN "- Building Odin BL package"
        BUILD_ODIN_BL_PACKAGE
        LOG_STEP_OUT
    fi

    LOG_STEP_IN "- Building Odin AP package"
    BUILD_ODIN_AP_PACKAGE
    LOG_STEP_OUT

    LOG_STEP_IN "- Building Odin CP package"
    BUILD_ODIN_CP_PACKAGE
    LOG_STEP_OUT

    LOG_STEP_IN "- Building Odin CSC package"
    BUILD_ODIN_CSC_PACKAGE
    LOG_STEP_OUT
fi

if $TARGET_BUILD_HEIMDALL_PACKAGE; then
    LOG_STEP_IN "- Building Heimdall flash folder"
    if $TARGET_BUILD_KERNEL_ONLY; then
        BUILD_KERNEL_ONLY_HEIMDALL_PACKAGE
    else
        BUILD_HEIMDALL_PACKAGE
    fi
    LOG_STEP_OUT
fi

if ! $TARGET_BUILD_FLASHABLE_ZIP; then
    exit 0
fi

if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
    LOG "- Building unsparse_super_empty.img"
    BUILD_SUPER_EMPTY

    LOG "- Generating dynamic_partitions_op_list"
    GENERATE_OP_LIST
fi

BROTLI_QUALITY="$TARGET_BROTLI_QUALITY"
$DEBUG && BROTLI_QUALITY=0

while IFS= read -r f; do
    PARTITION="$(basename "$f")"
    IS_VALID_PARTITION_NAME "$PARTITION" || continue
    [ -f "$TMP_DIR/$PARTITION.img" ] || continue

    (
        LOG "- Converting $PARTITION.img to $PARTITION.new.dat"
        EVAL "img2sdat -o \"$TMP_DIR\" \"$TMP_DIR/$PARTITION.img\"" || exit 1
        rm -f "$TMP_DIR/$PARTITION.img"

        LOG "- Compressing $PARTITION.new.dat"
        # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/common.py#3585
        EVAL "brotli --quality=\"$BROTLI_QUALITY\" --output=\"$TMP_DIR/$PARTITION.new.dat.br\" \"$TMP_DIR/$PARTITION.new.dat\"" || exit 1
        rm -f "$TMP_DIR/$PARTITION.new.dat"
    ) &
done < <(find "$WORK_DIR" -maxdepth 1 -type d)

# shellcheck disable=SC2046
wait $(jobs -p) || exit 1

LOG "- Generating updater-script"
GENERATE_UPDATER_SCRIPT

LOG "- Generating build_info.txt"
GENERATE_BUILD_INFO

LOG "- Generating OTA metadata"
GENERATE_OTA_METADATA

LOG "- Creating zip"
EVAL "rm -f \"$OUT_DIR/rom.zip\"" || exit 1
pushd "$TMP_DIR" > /dev/null

# 1. Compressed files (everything except zips, special dat files, META-INF)
find . -type f ! -name "*.new.dat.br" ! -name "*.patch.dat" > compressed.txt

# 2. Stored files (special dat files + META-INF folder)
find . -type f \( -name "*.new.dat.br" -o -name "*.patch.dat" -o -name "META-INF" \) > stored.txt
META_INF="./META-INF"

# Add batches
EVAL "7z a -tzip -mx=$TARGET_ROM_ZIP_COMPRESSION_LEVEL -mmt=$(nproc --all) \"$TMP_DIR/rom.zip\" @\"compressed.txt\""
EVAL "7z a -tzip -mx=0 -mmt=$(nproc --all) \"$TMP_DIR/rom.zip\" @\"stored.txt\" \"$META_INF\""

if ! $DEBUG; then
    LOG "- Signing zip"
    EVAL "signapk -w \"$PUBLIC_KEY_PATH\" \"$PRIVATE_KEY_PATH\" \"$TMP_DIR/rom.zip\" \"$OUT_DIR/$FILE_NAME\"" || exit 1
    rm -f "$TMP_DIR/rom.zip"
else
    mv -f "$TMP_DIR/rom.zip" "$OUT_DIR/$FILE_NAME"
fi

popd > /dev/null

exit 0
