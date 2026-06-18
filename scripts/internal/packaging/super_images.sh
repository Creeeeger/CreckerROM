# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/build_super_image.py#72
BUILD_SUPER_EMPTY()
{
    local CMD

    CMD="lpmake"
    # Full OTA packages use this empty super image only to seed dynamic
    # partition metadata before block_image_update writes partition contents.
    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/build_super_image.py#75
    CMD+=" --metadata-size \"65536\""
    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/core/config.mk#1033
    CMD+=" --super-name \"super\""
    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/build_super_image.py#85
    CMD+=" --metadata-slots \"2\""
    CMD+=" --device \"super:$TARGET_SUPER_PARTITION_SIZE\""
    CMD+=" --group \"$TARGET_SUPER_GROUP_NAME:$TARGET_SUPER_GROUP_SIZE\""
    if [ -f "$TMP_DIR/system.img" ]; then
        CMD+=" --partition \"system:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/vendor.img" ]; then
        CMD+=" --partition \"vendor:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/product.img" ]; then
        CMD+=" --partition \"product:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/system_ext.img" ]; then
        CMD+=" --partition \"system_ext:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/odm.img" ]; then
        CMD+=" --partition \"odm:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/vendor_dlkm.img" ]; then
        CMD+=" --partition \"vendor_dlkm:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/odm_dlkm.img" ]; then
        CMD+=" --partition \"odm_dlkm:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/system_dlkm.img" ]; then
        CMD+=" --partition \"system_dlkm:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    CMD+=" --output \"$TMP_DIR/unsparse_super_empty.img\""

    EVAL "$CMD" || exit 1
}

BUILD_ODIN_SUPER_IMAGE()
{
    local OUTPUT_FILE="$1"
    local IMAGE_DIR="$2"
    local CMD
    local PARTITION
    local PARTITION_SIZE
    local SUPER_PARTITIONS="system vendor product system_ext odm vendor_dlkm odm_dlkm system_dlkm"

    # Odin and Heimdall packages need a real sparse super.img, so use the signed
    # image directory as the logical partition source when custom AVB is active.
    CMD="lpmake"
    CMD+=" --metadata-size \"65536\""
    CMD+=" --super-name \"super\""
    CMD+=" --metadata-slots \"2\""
    if [ -f "$FW_DIR/$TARGET_FIRMWARE_PATH/os_partitions_metadata.txt" ] && \
            grep -q "^virtual_ab=true$" "$FW_DIR/$TARGET_FIRMWARE_PATH/os_partitions_metadata.txt"; then
        CMD+=" --virtual-ab"
    fi
    CMD+=" --device \"super:$TARGET_SUPER_PARTITION_SIZE\""
    CMD+=" --group \"$TARGET_SUPER_GROUP_NAME:$TARGET_SUPER_GROUP_SIZE\""

    for PARTITION in $SUPER_PARTITIONS; do
        if [ -f "$IMAGE_DIR/$PARTITION.img" ]; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$IMAGE_DIR/$PARTITION.img")"
            CMD+=" --partition \"$PARTITION:readonly:$PARTITION_SIZE:$TARGET_SUPER_GROUP_NAME\""
            CMD+=" --image \"$PARTITION=$IMAGE_DIR/$PARTITION.img\""
        fi
    done

    CMD+=" --sparse"
    CMD+=" --output \"$OUTPUT_FILE\""

    EVAL "$CMD" || exit 1
    SIGN_SUPER_IMAGE_IF_REQUIRED "$OUTPUT_FILE"
}
