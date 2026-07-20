CREATE_IMAGE_PACK()
{
    local ENTRY
    local PARTITION
    local KIND
    local FILE_NAME

    [ -d "$PACK_DIR" ] && rm -rf "$PACK_DIR"
    mkdir -p "$PACK_DIR"

    while IFS= read -r ENTRY; do
        cp -fa "$ENTRY" "$PACK_DIR/$(basename "$ENTRY")"
    done < <(find "$TMP_IMG_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "up_param.bin" \))

    if [ -d "$STAGING_DIR/keys" ]; then
        mkdir -p "$PACK_DIR/keys"
        while IFS= read -r ENTRY; do
            cp -fa "$ENTRY" "$PACK_DIR/keys/$(basename "$ENTRY")"
        done < <(find "$STAGING_DIR/keys" -maxdepth 1 -type f -name "*.avbpubkey")
    fi

    for ENTRY in $FIRMWARE_DESCRIPTOR_PACK_FILES; do
        [ -f "$ENTRY" ] || continue
        FILE_NAME="$(basename "$ENTRY")"
        cp -fa "$ENTRY" "$PACK_DIR/$FILE_NAME"
    done

    {
        # This manifest is the handoff contract from AVB signing to Odin,
        # Heimdall, and image-pack consumers.
        echo "device=$TARGET_CODENAME"
        echo "firmware=$TARGET_FIRMWARE"
        echo "algorithm=$VBMETA_SIGN_ALGORITHM"
        echo "low_security=$TARGET_AVB_LOW_SECURITY"
        echo "include_partition_descriptors=$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS"
        echo "vbmeta_flags=$TARGET_AVB_VBMETA_FLAGS"
        echo "preserve_samsung_signatures=$TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES"
        echo "vbmeta_key_path=$VBMETA_SIGN_KEY_PATH"
        echo "vbmeta_public_key_blob=keys/vbmeta.avbpubkey"
        if [ -f "$STAGING_DIR/keys/vbmeta.avbpubkey" ]; then
            echo "vbmeta_public_key_sha256=$(CALCULATE_SHA256 "$STAGING_DIR/keys/vbmeta.avbpubkey")"
        fi
        for PARTITION in $INCLUDED_HASH_PARTITIONS; do
            echo "hash_partition=$PARTITION"
        done
        for PARTITION in $INCLUDED_HASHTREE_PARTITIONS; do
            echo "hashtree_partition=$PARTITION"
        done
        for PARTITION in $INCLUDED_CHAIN_PARTITIONS; do
            echo "chain_partition=$PARTITION"
        done
        for PARTITION in $VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS; do
            echo "vbmeta_samsung_partition=$PARTITION"
        done
        for ENTRY in $FIRMWARE_DESCRIPTOR_PACK_COMPONENTS; do
            echo "firmware_component=$ENTRY"
        done
    } > "$PACK_DIR/avb_manifest.txt"

    if [ -f "$KEY_EXPORT_REPORT" ]; then
        cp -fa "$KEY_EXPORT_REPORT" "$PACK_DIR/avb_keys.txt"
    fi

    PRINT_KEY_SUMMARY
}
