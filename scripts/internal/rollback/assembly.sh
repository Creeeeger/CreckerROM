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
    # Rollback keeps old BL sidecar images but replaces sboot.bin with the new
    # firmware's copy before applying the LK patch/signing workflow.
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
    # AVB signing uses partition-style .img names; the BL folder needs the
    # Samsung component filenames that Odin/Heimdall flash.
    cp -fa "$SIGNED_IMAGE_DIR/bootloader.img" "$SIGNED_BL_DIR/sboot.bin"
    cp -fa "$SIGNED_IMAGE_DIR/harx.img" "$SIGNED_BL_DIR/harx.bin"
    cp -fa "$SIGNED_IMAGE_DIR/keystorage.img" "$SIGNED_BL_DIR/keystorage.bin"
    cp -fa "$SIGNED_IMAGE_DIR/ldfw.img" "$SIGNED_BL_DIR/ldfw.img"
    cp -fa "$SIGNED_IMAGE_DIR/tzsw.img" "$SIGNED_BL_DIR/tzsw.img"
}
