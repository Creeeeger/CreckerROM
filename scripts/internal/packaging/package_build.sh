TARGET_FIRMWARE_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

TMP_DIR="$OUT_DIR/package"
TARGET_BUILD_KERNEL_ONLY="${TARGET_BUILD_KERNEL_ONLY:-false}"
TARGET_BUILD_ODIN_PACKAGE="${TARGET_BUILD_ODIN_PACKAGE:-true}"
TARGET_BUILD_HEIMDALL_PACKAGE="${TARGET_BUILD_HEIMDALL_PACKAGE:-true}"
TARGET_ODIN_USE_SUPER_IMAGE="${TARGET_ODIN_USE_SUPER_IMAGE:-false}"
TARGET_ODIN_EXTRA_PARTITIONS="${TARGET_ODIN_EXTRA_PARTITIONS:-}"
TARGET_ODIN_EXTRA_IMAGE_MAP="${TARGET_ODIN_EXTRA_IMAGE_MAP:-${TARGET_AVB_FIRMWARE_IMAGE_MAP:-}}"
TARGET_BUILD_ODIN_CP_PACKAGE="${TARGET_BUILD_ODIN_CP_PACKAGE:-true}"
TARGET_BUILD_ODIN_CSC_PACKAGE="${TARGET_BUILD_ODIN_CSC_PACKAGE:-true}"
TARGET_RECOVERY_IMAGE_PATH="${TARGET_RECOVERY_IMAGE_PATH:-none}"
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

if [ "$TARGET_BUILD_KERNEL_ONLY" != "true" ] && [ "$TARGET_BUILD_KERNEL_ONLY" != "false" ]; then
    LOGE "TARGET_BUILD_KERNEL_ONLY must be true or false (got: $TARGET_BUILD_KERNEL_ONLY)"
    exit 1
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
PACKAGE_SUFFIX="-sign"
$DEBUG && ! $ROM_IS_OFFICIAL && PACKAGE_SUFFIX=""
PACKAGE_MODEL_IDENTIFIER="$(GET_PACKAGE_MODEL_IDENTIFIER)" || exit 1
ODIN_PACKAGE_DIR="$(GET_ODIN_PACKAGE_DIR "$PACKAGE_MODEL_IDENTIFIER")"

BUILD_DATE="$(date +%Y%m%d)"
PACKAGE_NAME="${ROM_DISPLAY_NAME}_${BUILD_DATE}_${TARGET_CODENAME}${PACKAGE_SUFFIX}"
HEIMDALL_DIR="$(GET_HEIMDALL_PACKAGE_DIR "$PACKAGE_MODEL_IDENTIFIER" "$PACKAGE_NAME")"
while compgen -G "$ODIN_PACKAGE_DIR/*_${PACKAGE_NAME}.tar.md5" > /dev/null || \
        [ -d "$HEIMDALL_DIR" ]; do
    INCREMENTAL=$((INCREMENTAL + 1))
    PACKAGE_NAME="${ROM_DISPLAY_NAME}_${BUILD_DATE}-${INCREMENTAL}_${TARGET_CODENAME}${PACKAGE_SUFFIX}"
    HEIMDALL_DIR="$(GET_HEIMDALL_PACKAGE_DIR "$PACKAGE_MODEL_IDENTIFIER" "$PACKAGE_NAME")"
done

export TARGET_AVB_IMAGE_PACK_DIR="$OUT_DIR/target/$TARGET_CODENAME/signed_images"
ODIN_AP_DIR="$OUT_DIR/target/$TARGET_CODENAME/odin_ap"
ODIN_EXTRA_DIR="$OUT_DIR/target/$TARGET_CODENAME/odin_extra"
ODIN_EXTRA_AP_DIR="$ODIN_EXTRA_DIR/ap"
ODIN_EXTRA_CP_DIR="$ODIN_EXTRA_DIR/cp"
ODIN_EXTRA_CSC_DIR="$ODIN_EXTRA_DIR/csc"

trap 'rm -rf "$TMP_DIR"' EXIT INT


# ]

[ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
$TARGET_BUILD_ODIN_PACKAGE && mkdir -p "$ODIN_PACKAGE_DIR"

if $TARGET_BUILD_KERNEL_ONLY; then
    COPY_KERNEL_TEST_IMAGES_TO_TMP
else
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

if $TARGET_ENABLE_CUSTOM_AVB && $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_AP_IMAGES; then
    LOG_STEP_IN "- Preparing Samsung download signer records before AVB"
    # LK removes FullHashSig before writing sparse filesystem bytes. Put the
    # final header and SignerInfo in place now, with FullHashSig zero, so AVB
    # hashes exactly the representation that reaches the partition.
    PREPARE_SAMSUNG_DOWNLOAD_IMAGES_FOR_AVB "$TMP_DIR"
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

exit 0
