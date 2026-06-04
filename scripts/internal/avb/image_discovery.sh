ERASE_FOOTER_IF_PRESENT()
{
    local IMAGE="$1"

    if RUN_AVBTOOL info_image --image "$IMAGE" &> /dev/null; then
        LOG "- Removing existing AVB footer from $(basename "$IMAGE") before re-signing"
        RUN_AVBTOOL erase_footer --image "$IMAGE" || exit 1
    fi
}

REMOVE_SAMSUNG_SIGNATURES_IF_PRESENT()
{
    local IMAGE="$1"
    local BEFORE_SIZE
    local AFTER_SIZE
    local TRIM_SIZE=0
    local CHANGED=false

    BEFORE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || exit 1

    if head -c 4096 "$IMAGE" | grep -a -q "SignerVer"; then
        # Samsung header signer blocks are not part of the clean AVB payload.
        # Only wipe them when the target explicitly opts out of preservation.
        LOG "- Removing Samsung header signature from $(basename "$IMAGE") before custom AVB re-signing"
        dd if="/dev/zero" of="$IMAGE" bs=256 seek=0 count=1 conv=notrunc &> /dev/null
        dd if="/dev/zero" of="$IMAGE" bs=256 seek=3 count=1 conv=notrunc &> /dev/null
        CHANGED=true
    fi

    if tail -c 4096 "$IMAGE" | grep -a -q "SignerVer03"; then
        TRIM_SIZE=784
    elif tail -c 4096 "$IMAGE" | grep -a -q "SignerVer02"; then
        TRIM_SIZE=512
    fi

    if [ "$TRIM_SIZE" -gt 0 ]; then
        LOG "- Removing Samsung footer signature from $(basename "$IMAGE") before custom AVB re-signing"
        truncate -s "-$TRIM_SIZE" "$IMAGE" || exit 1
        CHANGED=true
    fi

    if $CHANGED; then
        AFTER_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || exit 1
        LOG "- Samsung signature cleanup result for $(basename "$IMAGE"): $(FORMAT_SIZE "$BEFORE_SIZE") -> $(FORMAT_SIZE "$AFTER_SIZE")"
    fi
}

PREPARE_IMAGE_FOR_CUSTOM_AVB_SIGNING()
{
    local IMAGE="$1"

    # erase_footer is run before and after optional Samsung cleanup because
    # trimming signer bytes can expose an older AVB footer.
    ERASE_FOOTER_IF_PRESENT "$IMAGE"
    if [ "$TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES" = "true" ]; then
        AVB_DEBUG_LOG "Preserving Samsung signature areas in $(basename "$IMAGE") before custom AVB signing"
    else
        REMOVE_SAMSUNG_SIGNATURES_IF_PRESENT "$IMAGE"
    fi
    ERASE_FOOTER_IF_PRESENT "$IMAGE"
}

PREPARE_IMAGE_FOR_DESCRIPTOR_AVB_SIGNING()
{
    local IMAGE="$1"

    ERASE_FOOTER_IF_PRESENT "$IMAGE"
}

GET_FIRMWARE_DESCRIPTOR_FILENAME()
{
    local PARTITION="$1"
    local VALUE=""

    VALUE="$(GET_KV_VALUE "$PARTITION" "$TARGET_AVB_FIRMWARE_IMAGE_MAP")"
    [ -n "$VALUE" ] && echo "$VALUE"
}

GET_FIRMWARE_DESCRIPTOR_FILENAME_CANDIDATES()
{
    local PARTITION="$1"
    local FILE_NAME=""
    local CANDIDATES=""

    # Firmware components are not always named <partition>.img in Odin archives,
    # so try the configured map before generic image/bin fallbacks.
    FILE_NAME="$(GET_FIRMWARE_DESCRIPTOR_FILENAME "$PARTITION")"
    [ -n "$FILE_NAME" ] && APPEND_UNIQUE "CANDIDATES" "$FILE_NAME"
    APPEND_UNIQUE "CANDIDATES" "$PARTITION.img"
    APPEND_UNIQUE "CANDIDATES" "$PARTITION.bin"
    APPEND_UNIQUE "CANDIDATES" "$PARTITION"

    echo "$CANDIDATES"
}

LIST_TARGET_FIRMWARE_TARS()
{
    local FW_ODIN_DIR="$ODIN_DIR/${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}"

    [ -d "$FW_ODIN_DIR" ] || return 1

    find "$FW_ODIN_DIR" -maxdepth 1 -type f \( -name "*.md5" -o -name "*.tar" \) | sort -r
}

EXTRACT_FILE_FROM_TAR_TO_PATH()
{
    local TAR_FILE="$1"
    local ENTRY_NAME="$2"
    local OUTPUT_PATH="$3"
    local OUTPUT_DIR

    OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT_PATH" "$OUTPUT_PATH.lz4"

    if FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME"; then
        EVAL "tar xf \"$TAR_FILE\" -C \"$OUTPUT_DIR\" \"$ENTRY_NAME\"" || exit 1
    elif FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME.lz4"; then
        EVAL "tar xf \"$TAR_FILE\" -C \"$OUTPUT_DIR\" \"$ENTRY_NAME.lz4\"" || exit 1
        EVAL "lz4 -d --rm \"$OUTPUT_DIR/$ENTRY_NAME.lz4\" \"$OUTPUT_PATH\"" || exit 1
    else
        LOGE "File $ENTRY_NAME(.lz4) not found in $TAR_FILE"
        exit 1
    fi

    [ -f "$OUTPUT_PATH" ] || {
        LOGE "Failed to extract $ENTRY_NAME from $TAR_FILE"
        exit 1
    }
}

GET_FIRMWARE_DESCRIPTOR_SOURCE_PATH()
{
    local PARTITION="$1"
    local QUIET="${2:-false}"
    local FILE_NAME=""
    local SOURCE_PATH=""
    local CANDIDATES=""
    local FW_ODIN_DIR="$ODIN_DIR/${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}"
    local EXTRACTED_CANDIDATE=""
    local TAR_FILE=""

    CANDIDATES="$(GET_FIRMWARE_DESCRIPTOR_FILENAME_CANDIDATES "$PARTITION")"
    [ -n "$CANDIDATES" ] || return 1

    for FILE_NAME in $CANDIDATES; do
        # Prefer freshly signed bootloader components so descriptor vbmeta
        # covers the same bytes that later go into BL/Odin packages.
        if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_BOOTLOADER && \
                [ -f "$TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR/$FILE_NAME" ]; then
            LOG "- Using signed bootloader component $FILE_NAME for $PARTITION AVB descriptor" >&2
            echo "$TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR/$FILE_NAME"
            return 0
        fi

        for EXTRACTED_CANDIDATE in \
            "$FW_DIR/$TARGET_FIRMWARE_PATH/$FILE_NAME" \
            "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/$FILE_NAME" \
            "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/$FILE_NAME"; do
            if [ -f "$EXTRACTED_CANDIDATE" ]; then
                echo "$EXTRACTED_CANDIDATE"
                return 0
            fi
        done

        SOURCE_PATH="$STAGING_DIR/fw_odin/$FILE_NAME"
        if [ -f "$SOURCE_PATH" ]; then
            echo "$SOURCE_PATH"
            return 0
        fi

        # Cache extracted Odin entries in staging; several descriptor lookups
        # may need the same opaque firmware image.
        while IFS= read -r TAR_FILE; do
            if ! FILE_EXISTS_IN_TAR "$TAR_FILE" "$FILE_NAME" && ! FILE_EXISTS_IN_TAR "$TAR_FILE" "$FILE_NAME.lz4"; then
                continue
            fi

            LOG "- Extracting $FILE_NAME from $(basename "$TAR_FILE") for $PARTITION" >&2
            EXTRACT_FILE_FROM_TAR_TO_PATH "$TAR_FILE" "$FILE_NAME" "$SOURCE_PATH"
            echo "$SOURCE_PATH"
            return 0
        done < <(LIST_TARGET_FIRMWARE_TARS)
    done

    if ! $QUIET; then
        LOGW "Firmware descriptor source not found for $PARTITION in extracted firmware or stock Odin tars under $FW_ODIN_DIR: tried $CANDIDATES"
    fi
    return 1
}

GET_DESCRIPTOR_SOURCE_PATH()
{
    local PARTITION="$1"
    local SOURCE_PATH=""

    SOURCE_PATH="$(GET_STOCK_IMAGE_PATH "$PARTITION" || true)"
    if [ -n "$SOURCE_PATH" ] && [ -f "$SOURCE_PATH" ]; then
        echo "$SOURCE_PATH"
        return 0
    fi

    GET_FIRMWARE_DESCRIPTOR_SOURCE_PATH "$PARTITION"
}

LOG_PARTITION_SIZE_STATUS()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local SOURCE="$4"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local IMAGE_SIZE
    local ROUNDED_IMAGE_SIZE
    local MAX_IMAGE_SIZE=""

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    ROUNDED_IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"
    MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE" || true)"

    if [ -n "$MAX_IMAGE_SIZE" ]; then
        LOG "- AVB size check for $PARTITION: partition=$(FORMAT_SIZE "$PARTITION_SIZE") source=$SOURCE image=$(FORMAT_SIZE "$IMAGE_SIZE") rounded_image=$(FORMAT_SIZE "$ROUNDED_IMAGE_SIZE") max_payload=$(FORMAT_SIZE "$MAX_IMAGE_SIZE")"
    else
        LOG "- AVB size check for $PARTITION: partition=$(FORMAT_SIZE "$PARTITION_SIZE") source=$SOURCE image=$(FORMAT_SIZE "$IMAGE_SIZE") rounded_image=$(FORMAT_SIZE "$ROUNDED_IMAGE_SIZE")"
    fi
}

PRINT_AVB_SIZE_MISMATCH_DIAGNOSTICS()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local SOURCE="$4"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local IMAGE_SIZE
    local ROUNDED_IMAGE_SIZE
    local MAX_IMAGE_SIZE=""
    local MIN_PARTITION_SIZE=""
    local STOCK_IMAGE_SIZE=""

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    ROUNDED_IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"
    MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE" || true)"
    MIN_PARTITION_SIZE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND" || true)"
    STOCK_IMAGE_SIZE="$(GET_STOCK_IMAGE_PARTITION_SIZE "$PARTITION" || true)"

    LOGE "AVB size mismatch for $PARTITION: partition=$(FORMAT_SIZE "$PARTITION_SIZE") source=$SOURCE image=$(FORMAT_SIZE "$IMAGE_SIZE") rounded_image=$(FORMAT_SIZE "$ROUNDED_IMAGE_SIZE")"
    [ -n "$MAX_IMAGE_SIZE" ] && LOGE "AVB max payload for $PARTITION with current $KIND footer: $(FORMAT_SIZE "$MAX_IMAGE_SIZE")"
    [ -n "$MIN_PARTITION_SIZE" ] && LOGE "Minimum partition size required for current $PARTITION image with $KIND footer: $(FORMAT_SIZE "$MIN_PARTITION_SIZE")"
    [ -n "$STOCK_IMAGE_SIZE" ] && LOGE "Current stock $PARTITION image size on disk: $(FORMAT_SIZE "$STOCK_IMAGE_SIZE")"
}

ASSERT_SIGNED_IMAGE_PARTITION_SIZE()
{
    local IMAGE="$1"
    local PARTITION="$2"
    local EXPECTED_SIZE="$3"
    local IMAGE_SIZE

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || exit 1
    if [ "$IMAGE_SIZE" != "$EXPECTED_SIZE" ]; then
        LOGE "Signed $PARTITION image size mismatch: expected partition size $EXPECTED_SIZE, got $IMAGE_SIZE"
        exit 1
    fi
}
