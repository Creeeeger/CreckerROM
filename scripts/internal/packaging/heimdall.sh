IS_HEIMDALL_DYNAMIC_PARTITION_IMAGE()
{
    case "$1" in
        system.img | vendor.img | product.img | system_ext.img | odm.img | \
            vendor_dlkm.img | odm_dlkm.img | system_dlkm.img)
            return 0
            ;;
    esac

    return 1
}

COPY_HEIMDALL_IMAGES_FROM_DIR()
{
    local SOURCE_DIR="$1"
    local ENTRY
    local FILE_NAME

    [ -d "$SOURCE_DIR" ] || return 0

    while IFS= read -r ENTRY; do
        FILE_NAME="$(basename "$ENTRY")"
        # Dynamic partitions are represented by super.img when the target uses
        # one, so individual logical images are intentionally skipped.
        if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ] && \
                IS_HEIMDALL_DYNAMIC_PARTITION_IMAGE "$FILE_NAME"; then
            continue
        fi
        if [ -f "$HEIMDALL_DIR/$FILE_NAME" ]; then
            continue
        fi

        LOG "- Copying Heimdall image $FILE_NAME"
        cp -fa "$ENTRY" "$HEIMDALL_DIR/$FILE_NAME"
    done < <(find "$SOURCE_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "*.bin" \) | sort)
}

BUILD_HEIMDALL_PACKAGE()
{
    local IMAGE_DIR="$TMP_DIR"

    if $TARGET_ENABLE_CUSTOM_AVB; then
        IMAGE_DIR="$TARGET_AVB_IMAGE_PACK_DIR"
    fi

    [ -d "$HEIMDALL_DIR" ] && rm -rf "$HEIMDALL_DIR"
    mkdir -p "$HEIMDALL_DIR"

    if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
        if $TARGET_BUILD_ODIN_PACKAGE && [ -f "$ODIN_AP_DIR/super.img" ]; then
            LOG "- Copying Heimdall image super.img"
            cp -fa "$ODIN_AP_DIR/super.img" "$HEIMDALL_DIR/super.img"
        else
            LOG "- Building super.img for Heimdall"
            BUILD_ODIN_SUPER_IMAGE "$HEIMDALL_DIR/super.img" "$IMAGE_DIR"
        fi
    fi

    if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_BOOTLOADER; then
        COPY_HEIMDALL_IMAGES_FROM_DIR "$TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR"
    fi
    COPY_HEIMDALL_IMAGES_FROM_DIR "$ODIN_EXTRA_AP_DIR"
    COPY_HEIMDALL_IMAGES_FROM_DIR "$ODIN_EXTRA_CP_DIR"
    COPY_HEIMDALL_IMAGES_FROM_DIR "$ODIN_EXTRA_CSC_DIR"
    COPY_HEIMDALL_IMAGES_FROM_DIR "$IMAGE_DIR"
    [ "$IMAGE_DIR" != "$TMP_DIR" ] && COPY_HEIMDALL_IMAGES_FROM_DIR "$TMP_DIR"

    cp -fa "$SRC_DIR/prebuilts/extras/flash_heimdall.sh" "$HEIMDALL_DIR/flash_all.sh"
    chmod 0755 "$HEIMDALL_DIR/flash_all.sh"

    find "$HEIMDALL_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "*.bin" \) -print -quit | grep -q . || {
        LOGE "No Heimdall flash folder contents were generated"
        exit 1
    }
}

BUILD_KERNEL_ONLY_HEIMDALL_PACKAGE()
{
    local IMAGE

    [ -d "$HEIMDALL_DIR" ] && rm -rf "$HEIMDALL_DIR"
    mkdir -p "$HEIMDALL_DIR"

    for IMAGE in boot.img dtbo.img vbmeta.img; do
        [ -f "$TARGET_AVB_IMAGE_PACK_DIR/$IMAGE" ] || {
            LOGE "Missing signed kernel test image: $TARGET_AVB_IMAGE_PACK_DIR/$IMAGE"
            exit 1
        }
        LOG "- Copying Heimdall image $IMAGE"
        cp -fa "$TARGET_AVB_IMAGE_PACK_DIR/$IMAGE" "$HEIMDALL_DIR/$IMAGE"
    done

    cp -fa "$SRC_DIR/prebuilts/extras/flash_kernel.sh" "$HEIMDALL_DIR/flash_kernel.sh"
    chmod 0755 "$HEIMDALL_DIR/flash_kernel.sh"
}
