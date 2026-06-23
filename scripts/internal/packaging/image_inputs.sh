GET_AVB_IMAGE_PACK_MANIFEST()
{
    local MANIFEST="$TARGET_AVB_IMAGE_PACK_DIR/avb_manifest.txt"

    [ -f "$MANIFEST" ] && echo "$MANIFEST"
}

LIST_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS()
{
    local MANIFEST=""

    MANIFEST="$(GET_AVB_IMAGE_PACK_MANIFEST || true)"
    [ -n "$MANIFEST" ] || return 0

    # firmware_component entries are emitted by AVB signing for opaque files
    # that package builders must carry alongside rebuilt partition images.
    grep '^firmware_component=' "$MANIFEST" | cut -d '=' -f 2-
}

SHOULD_PACKAGE_BOOTLOADER_COMPONENTS_IN_AP()
{
    # When a dedicated BL Odin package is built, keep bootloader components out
    # of AP to avoid flashing the same partition from two archives.
    if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_BOOTLOADER && $TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE; then
        return 1
    fi

    return 0
}

IS_BOOTLOADER_COMPONENT()
{
    local PARTITION="$1"
    local COMPONENT_FILE="$2"
    local COMPONENT
    local COMPONENT_PARTITION
    local BOOTLOADER_COMPONENTS="sboot.bin ldfw.img tzsw.img keystorage.bin harx.bin ssp.img tzar.img uh.bin vbmeta_samsung.img up_param.bin"

    for COMPONENT in $BOOTLOADER_COMPONENTS; do
        COMPONENT_PARTITION="${COMPONENT%.*}"
        if [ "$COMPONENT_FILE" = "$COMPONENT" ] || [ "$PARTITION" = "$COMPONENT_PARTITION" ]; then
            return 0
        fi
    done

    return 1
}

COPY_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS_TO_TMP()
{
    local ENTRY=""
    local PARTITION=""
    local COMPONENT_FILE=""

    $TARGET_ENABLE_CUSTOM_AVB || return 0

    while IFS= read -r ENTRY; do
        [ -n "$ENTRY" ] || continue
        PARTITION="${ENTRY%%=*}"
        COMPONENT_FILE="${ENTRY#*=}"
        [ "$PARTITION" = "bootloader" ] && continue
        [ -f "$TARGET_AVB_IMAGE_PACK_DIR/$COMPONENT_FILE" ] || continue

        LOG "- Copying AVB firmware component for zip: $PARTITION ($COMPONENT_FILE)"
        cp -fa "$TARGET_AVB_IMAGE_PACK_DIR/$COMPONENT_FILE" "$TMP_DIR/$COMPONENT_FILE"
    done < <(LIST_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS)
}

RESOLVE_TARGET_RECOVERY_IMAGE_PATH()
{
    if [ -n "$TARGET_RECOVERY_IMAGE_PATH" ] && [ "$TARGET_RECOVERY_IMAGE_PATH" != "none" ]; then
        [ -f "$TARGET_RECOVERY_IMAGE_PATH" ] && echo "$TARGET_RECOVERY_IMAGE_PATH" && return 0
        LOGW "Configured recovery image does not exist: $TARGET_RECOVERY_IMAGE_PATH"
        return 1
    fi

    return 1
}

COPY_TARGET_RECOVERY_IMAGE_TO_TMP()
{
    local RECOVERY_IMAGE=""

    RECOVERY_IMAGE="$(RESOLVE_TARGET_RECOVERY_IMAGE_PATH || true)"
    [ -n "$RECOVERY_IMAGE" ] || return 0

    mkdir -p "$WORK_DIR/kernel"
    if [[ "$RECOVERY_IMAGE" == *.zip ]]; then
        LOG "- Extracting target recovery.img from ${RECOVERY_IMAGE//$SRC_DIR\//}"
        unzip -p "$RECOVERY_IMAGE" "*.img" > "$WORK_DIR/kernel/recovery.img" || exit 1
    else
        LOG "- Copying target recovery.img from ${RECOVERY_IMAGE//$SRC_DIR\//}"
        cp -fa "$RECOVERY_IMAGE" "$WORK_DIR/kernel/recovery.img"
    fi
    cp -fa "$WORK_DIR/kernel/recovery.img" "$TMP_DIR/recovery.img"
}

COPY_KERNEL_TEST_IMAGES_TO_TMP()
{
    local IMAGE

    for IMAGE in boot dtbo; do
        [ -f "$WORK_DIR/kernel/$IMAGE.img" ] || {
            LOGE "Missing kernel test image: $WORK_DIR/kernel/$IMAGE.img"
            exit 1
        }
        LOG "- Copying $IMAGE.img"
        cp -fa "$WORK_DIR/kernel/$IMAGE.img" "$TMP_DIR/$IMAGE.img"
    done
}
