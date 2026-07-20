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
