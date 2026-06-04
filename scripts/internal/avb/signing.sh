SIGN_IMAGE()
{
    local IMAGE="$1"
    local PARTITION="$2"
    local KIND="$3"
    local PARTITION_SIZE="$4"
    local CMD=()

    # Built ROM images are modified in place and later copied into the signed
    # image pack, so cleanup and signing both operate on TMP_IMG_DIR contents.
    PREPARE_IMAGE_FOR_CUSTOM_AVB_SIGNING "$IMAGE"
    BUILD_SIGN_IMAGE_CMD CMD "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE" "sign"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    ASSERT_SIGNED_IMAGE_PARTITION_SIZE "$IMAGE" "$PARTITION" "$PARTITION_SIZE"
    REGISTER_PARTITION_KEY_USAGE_IF_NEEDED "$PARTITION"
    DUMP_AVB_INFO_IMAGE "$IMAGE" "$PARTITION.img"
}

SIGN_DESCRIPTOR_IMAGE()
{
    local IMAGE="$1"
    local PARTITION="$2"
    local KIND="$3"
    local PARTITION_SIZE="$4"
    local CMD=()

    # Descriptor images are temporary copies of stock firmware inputs; only
    # their descriptors are included in vbmeta.
    PREPARE_IMAGE_FOR_DESCRIPTOR_AVB_SIGNING "$IMAGE"
    BUILD_SIGN_IMAGE_CMD CMD "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE" "sign"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    ASSERT_SIGNED_IMAGE_PARTITION_SIZE "$IMAGE" "$PARTITION" "$PARTITION_SIZE"
    REGISTER_PARTITION_KEY_USAGE_IF_NEEDED "$PARTITION"
    DUMP_AVB_INFO_IMAGE "$IMAGE" "$PARTITION.img"
}

SIGN_BUILT_PARTITION()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local PARTITION_SIZE
    local PARTITION_SIZE_INFO=""
    local PARTITION_SIZE_SOURCE=""
    local KIND
    local CHAIN_LOCATION
    local INCLUDE_IN_TOPLEVEL="false"

    [ -f "$IMAGE" ] || return 0
    LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS" && return 0

    LOG "- Resolving AVB partition size for $PARTITION"
    PARTITION_SIZE_INFO="$(GET_PARTITION_SIZE_INFO "$PARTITION")" || {
        LOGE "Unable to determine partition size for $PARTITION"
        exit 1
    }
    PARTITION_SIZE="${PARTITION_SIZE_INFO%%|*}"
    PARTITION_SIZE_SOURCE="${PARTITION_SIZE_INFO#*|}"
    if [ -z "$PARTITION_SIZE" ]; then
        if ! LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASH_PARTITIONS" && \
                ! LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASHTREE_PARTITIONS"; then
            LOGW "Skipping optional AVB partition $PARTITION due missing partition size metadata"
            REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
            REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"
            return 0
        fi

        LOGE "Unable to determine partition size for $PARTITION"
        exit 1
    fi

    ASSERT_FIXED_CHAIN_PARTITION_SIZE_SOURCE "$PARTITION" "$PARTITION_SIZE_SOURCE"
    PREPARE_IMAGE_FOR_CUSTOM_AVB_SIGNING "$IMAGE"

    KIND="$(GET_SIGN_KIND "$PARTITION")"
    PARTITION_SIZE="$(RESOLVE_SIGN_PARTITION_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE")"
    LOG_PARTITION_SIZE_STATUS "$PARTITION" "$KIND" "$PARTITION_SIZE" "$PARTITION_SIZE_SOURCE"

    if ! CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE"; then
        if [ "$KIND" = "hashtree" ] && [ "$TARGET_AVB_ALLOW_HASHTREE_FALLBACK" = "true" ] && \
                CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "hash" "$PARTITION_SIZE"; then
            LOGW "Falling back to AVB hash footer for $PARTITION (hashtree does not fit within $PARTITION_SIZE bytes)"
            KIND="hash"
            SET_PARTITION_SIGN_KIND "$PARTITION" "$KIND"
        else
            PRINT_AVB_SIZE_MISMATCH_DIAGNOSTICS "$PARTITION" "$KIND" "$PARTITION_SIZE" "$PARTITION_SIZE_SOURCE"
            LOGE "Unable to fit AVB $KIND footer for $PARTITION within partition size $PARTITION_SIZE"
            exit 1
        fi
    fi

    LOG "- Signing $PARTITION.img ($KIND)"
    SIGN_IMAGE "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE"

    SHOULD_INCLUDE_IN_TOPLEVEL_VBMETA "$PARTITION" && INCLUDE_IN_TOPLEVEL="true"
    CHAIN_LOCATION="$(GET_CHAIN_LOCATION "$PARTITION")"
    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ]; then
        LOG "- Signed $PARTITION.img but not adding it to top-level vbmeta because partition descriptors are disabled"
    elif [ "$INCLUDE_IN_TOPLEVEL" = "true" ] && [ -n "$CHAIN_LOCATION" ] && [ -n "$(GET_KV_VALUE "$PARTITION" "$ORIGINAL_CHAIN_PARTITIONS")" ]; then
        # Preserve stock chain descriptors only when the stock vbmeta already
        # chained this partition; otherwise include the signed image directly.
        APPEND_UNIQUE "ACTIVE_CHAIN_PARTITIONS" "$PARTITION=$CHAIN_LOCATION"
        APPEND_UNIQUE "INCLUDED_CHAIN_PARTITIONS" "$PARTITION=$CHAIN_LOCATION"
    elif [ "$INCLUDE_IN_TOPLEVEL" = "true" ]; then
        APPEND_UNIQUE "DIRECT_DESCRIPTOR_IMAGES" "$IMAGE"
        if [ "$KIND" = "hashtree" ]; then
            APPEND_UNIQUE "INCLUDED_HASHTREE_PARTITIONS" "$PARTITION"
        else
            APPEND_UNIQUE "INCLUDED_HASH_PARTITIONS" "$PARTITION"
        fi
    else
        LOG "- Signed $PARTITION.img but not adding it to top-level vbmeta because it is not present in the original vbmeta"
    fi
    APPEND_UNIQUE "SIGNED_PARTITIONS" "$PARTITION"
}

SIGN_EXTERNAL_DESCRIPTOR_PARTITIONS()
{
    local PARTITION
    local KIND
    local SOURCE_PATH
    local SOURCE_SIZE
    local PARTITION_SIZE
    local IMAGE
    local INCLUDE_IN_TOPLEVEL="false"

    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ]; then
        LOG "- Skipping external AVB descriptor images because top-level vbmeta partition descriptors are disabled"
        return 0
    fi

    for PARTITION in $HASH_PARTITIONS $HASHTREE_PARTITIONS; do
        INCLUDE_IN_TOPLEVEL="false"

        if LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS"; then
            continue
        fi

        KIND="$(GET_SIGN_KIND "$PARTITION")"
        SOURCE_PATH="$(GET_DESCRIPTOR_SOURCE_PATH "$PARTITION" || true)"
        if [ -z "$SOURCE_PATH" ] || [ ! -f "$SOURCE_PATH" ]; then
            if LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASH_PARTITIONS" || LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASHTREE_PARTITIONS"; then
                LOGE "Unable to resolve descriptor source for required partition $PARTITION"
                exit 1
            fi

            LOGW "Skipping optional AVB descriptor partition $PARTITION because the source image is unavailable"
            REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
            REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"
            continue
        fi
        SOURCE_SIZE="$(GET_IMAGE_SIZE "$SOURCE_PATH")" || exit 1
        PARTITION_SIZE="$(ESTIMATE_PARTITION_SIZE_FROM_IMAGE_PATH "$SOURCE_PATH" "$KIND")" || exit 1
        IMAGE="$STAGING_DIR/external_descriptors/${PARTITION}.img"

        mkdir -p "$(dirname "$IMAGE")"
        cp -fa "$SOURCE_PATH" "$IMAGE"

        LOG "- Preparing external AVB descriptor for $PARTITION from $(basename "$SOURCE_PATH"): source_image=$(FORMAT_SIZE "$SOURCE_SIZE") estimated_partition=$(FORMAT_SIZE "$PARTITION_SIZE")"
        SIGN_DESCRIPTOR_IMAGE "$IMAGE" "$PARTITION" "$KIND" "$PARTITION_SIZE"

        # External descriptors cover firmware images that are packaged but not
        # rebuilt in this ROM build, such as opaque bootloader components.
        SHOULD_INCLUDE_IN_TOPLEVEL_VBMETA "$PARTITION" && INCLUDE_IN_TOPLEVEL="true"
        if [ "$INCLUDE_IN_TOPLEVEL" = "true" ]; then
            APPEND_UNIQUE "DIRECT_DESCRIPTOR_IMAGES" "$IMAGE"
            if [ "$KIND" = "hashtree" ]; then
                APPEND_UNIQUE "INCLUDED_HASHTREE_PARTITIONS" "$PARTITION"
            else
                APPEND_UNIQUE "INCLUDED_HASH_PARTITIONS" "$PARTITION"
            fi
        else
            LOG "- Prepared firmware descriptor image for $PARTITION but not adding it to top-level vbmeta because it is not present in the original vbmeta"
        fi
        APPEND_UNIQUE "SIGNED_PARTITIONS" "$PARTITION"
        APPEND_UNIQUE "FIRMWARE_DESCRIPTOR_PACK_FILES" "$SOURCE_PATH"
        APPEND_UNIQUE "FIRMWARE_DESCRIPTOR_PACK_COMPONENTS" "$PARTITION=$(basename "$SOURCE_PATH")"
    done
}

DETECT_EXISTING_AVB_SIGN_KIND()
{
    local IMAGE="$1"
    local KIND=""

    [ -f "$IMAGE" ] || return 0

    KIND="$(
        "$AVB_PYTHON_BIN" "$AVB_METADATA_TOOL" \
            --avbtool "$AVBTOOL_PATH" kind --image "$IMAGE"
    )" || true

    [ -n "$KIND" ] && echo "$KIND"
}

RESOLVE_CHAIN_PARTITION_SIGN_KIND()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local STOCK_IMAGE=""
    local KIND=""

    KIND="$(GET_SIGN_KIND "$PARTITION")"
    if LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS" || LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
        echo "$KIND"
        return 0
    fi

    STOCK_IMAGE="$(GET_STOCK_FIRMWARE_IMAGE_PATH "$PARTITION" || true)"
    [ -n "$STOCK_IMAGE" ] && KIND="$(DETECT_EXISTING_AVB_SIGN_KIND "$STOCK_IMAGE")"
    [ -z "$KIND" ] && KIND="$(DETECT_EXISTING_AVB_SIGN_KIND "$IMAGE")"
    [ -n "$KIND" ] && echo "$KIND" || echo "hash"
}

SIGN_CHAIN_PARTITIONS()
{
    local ENTRY
    local PARTITION
    local KIND

    for ENTRY in $CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        [ -f "$TMP_IMG_DIR/$PARTITION.img" ] || continue
        LIST_HAS_ITEM "$PARTITION" "$SIGNED_PARTITIONS" && continue

        KIND="$(RESOLVE_CHAIN_PARTITION_SIGN_KIND "$PARTITION")"
        SET_PARTITION_SIGN_KIND "$PARTITION" "$KIND"
        LOG "- Signing chained AVB partition $PARTITION using $KIND footer"
        SIGN_BUILT_PARTITION "$PARTITION"
    done
}

BUILD_OPTIONAL_PROPS()
{
    local ENTRY
    local KEY
    local VALUE
    local SECURITY_PATCH_OVERRIDE="${TARGET_AVB_VBMETA_SECURITY_PATCH_OVERRIDE:-2026-02-01}"
    local BOOT_OS_VERSION
    local BOOT_PATCH
    local SYSTEM_OS_VERSION
    local SYSTEM_PATCH
    local VENDOR_OS_VERSION
    local VENDOR_PATCH

    VBMETA_PROPS=()

    # Prefer stock vbmeta properties so boot/system/vendor version descriptors
    # remain compatible with the firmware this ROM is based on.
    if [ "$TARGET_AVB_USE_ORIGINAL_VBMETA_PROPS" = "true" ] && [ -n "$ORIGINAL_VBMETA_PROPS" ]; then
        for ENTRY in $ORIGINAL_VBMETA_PROPS; do
            KEY="${ENTRY%%=*}"
            VALUE="${ENTRY#*=}"
            case "$KEY" in
                "com.android.build.boot.security_patch" | \
                "com.android.build.system.security_patch" | \
                "com.android.build.vendor.security_patch")
                    [ "$SECURITY_PATCH_OVERRIDE" != "preserve" ] && VALUE="$SECURITY_PATCH_OVERRIDE"
                    ;;
            esac
            VBMETA_PROPS+=("--prop" "$KEY:$VALUE")
        done
        LOG_PARTITION_SET "Using original vbmeta props" "$ORIGINAL_VBMETA_PROPS"
        if [ "$SECURITY_PATCH_OVERRIDE" = "preserve" ]; then
            AVB_DEBUG_LOG "Preserving original vbmeta boot/system/vendor security_patch props"
        else
            AVB_DEBUG_LOG "Overriding vbmeta boot/system/vendor security_patch props to $SECURITY_PATCH_OVERRIDE"
        fi
        return 0
    fi

    BOOT_OS_VERSION="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/boot.img_metadata.txt" "os_version")"
    BOOT_PATCH="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/boot.img_metadata.txt" "os_patch_level")"
    SYSTEM_OS_VERSION="$(GET_PROP "system" "ro.build.version.release")"
    SYSTEM_PATCH="$(GET_PROP "system" "ro.build.version.security_patch")"
    VENDOR_OS_VERSION="$(GET_PROP "vendor" "ro.vendor.build.version.release")"
    [ -z "$VENDOR_OS_VERSION" ] && VENDOR_OS_VERSION="$(GET_PROP "vendor" "ro.build.version.release")"
    VENDOR_PATCH="$(GET_PROP "vendor" "ro.vendor.build.version.security_patch")"
    [ -z "$VENDOR_PATCH" ] && VENDOR_PATCH="$(GET_PROP "vendor" "ro.build.version.security_patch")"
    BOOT_PATCH="$SECURITY_PATCH_OVERRIDE"
    SYSTEM_PATCH="$SECURITY_PATCH_OVERRIDE"
    VENDOR_PATCH="$SECURITY_PATCH_OVERRIDE"

    [ -n "$BOOT_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.boot.os_version:$BOOT_OS_VERSION")
    [ -n "$BOOT_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.boot.security_patch:$BOOT_PATCH")
    [ -n "$SYSTEM_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.system.os_version:$SYSTEM_OS_VERSION")
    [ -n "$SYSTEM_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.system.security_patch:$SYSTEM_PATCH")
    [ -n "$VENDOR_OS_VERSION" ] && VBMETA_PROPS+=("--prop" "com.android.build.vendor.os_version:$VENDOR_OS_VERSION")
    [ -n "$VENDOR_PATCH" ] && VBMETA_PROPS+=("--prop" "com.android.build.vendor.security_patch:$VENDOR_PATCH")
}

BUILD_ORIGINAL_KERNEL_CMDLINE_DESCRIPTOR_IMAGE()
{
    local OUTPUT="$STAGING_DIR/original_kernel_cmdline_descriptors.img"

    [ -s "$ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE" ] || return 1

    # Kernel cmdline descriptors are not tied to an image file, so rebuild them
    # as a descriptor-only vbmeta image and include that in the final vbmeta.
    "$AVB_PYTHON_BIN" "$AVB_METADATA_TOOL" \
        --avbtool "$AVBTOOL_PATH" make-kernel-cmdline-image \
        --input "$ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE" \
        --output "$OUTPUT" || return 1

    echo "$OUTPUT"
}

MAKE_TOPLEVEL_VBMETA()
{
    local ENTRY
    local PARTITION
    local LOCATION
    local CMD=()
    local PUBLIC_KEY_BLOB=""
    local CHAIN_OPTION="--chain_partition"
    local ORIGINAL_KERNEL_CMDLINE_IMAGE=""

    # This is the only vbmeta image allowed to carry the top-level rollback slot
    # and any active chain descriptors.
    BUILD_OPTIONAL_PROPS

    CMD=(
        make_vbmeta_image
        --output "$TMP_IMG_DIR/vbmeta.img"
        --algorithm "$VBMETA_SIGN_ALGORITHM"
        --rollback_index "$TARGET_AVB_ROLLBACK_INDEX"
        --rollback_index_location "$TARGET_AVB_ROLLBACK_INDEX_LOCATION"
        --flags "$TARGET_AVB_VBMETA_FLAGS"
        --key "$VBMETA_SIGN_KEY_PATH"
    )

    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" = "true" ]; then
        for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
            CMD+=(--include_descriptors_from_image "$ENTRY")
        done
    else
        LOG "- Creating vbmeta without hash, hashtree, or chain partition descriptors"
    fi

    ORIGINAL_KERNEL_CMDLINE_IMAGE="$(BUILD_ORIGINAL_KERNEL_CMDLINE_DESCRIPTOR_IMAGE || true)"
    if [ -n "$ORIGINAL_KERNEL_CMDLINE_IMAGE" ] && [ -f "$ORIGINAL_KERNEL_CMDLINE_IMAGE" ]; then
        CMD+=(--include_descriptors_from_image "$ORIGINAL_KERNEL_CMDLINE_IMAGE")
    fi

    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" = "true" ]; then
        for ENTRY in $ACTIVE_CHAIN_PARTITIONS; do
            PARTITION="${ENTRY%%=*}"
            LOCATION="${ENTRY#*=}"
            RESOLVE_PARTITION_SIGNING_CONFIG "$PARTITION" "$(GET_SIGN_KIND "$PARTITION")"
            if [ "$PARTITION_SIGN_ALGORITHM" = "NONE" ] || [ -z "$PARTITION_SIGN_KEY_PATH" ]; then
                LOGE "Chained partition $PARTITION must use a real signing key"
                exit 1
            fi
            PUBLIC_KEY_BLOB="$(GET_CHAIN_PUBLIC_KEY_BLOB "$PARTITION" "$PARTITION_SIGN_KEY_PATH")"
            CHAIN_OPTION="--chain_partition"
            [ "$PARTITION_SIGN_DO_NOT_USE_AB" = "true" ] && CHAIN_OPTION="--chain_partition_do_not_use_ab"
            CMD+=("$CHAIN_OPTION" "${PARTITION}:${LOCATION}:$PUBLIC_KEY_BLOB")
        done
    fi

    if [ "${#VBMETA_PROPS[@]}" -gt 0 ]; then
        CMD+=("${VBMETA_PROPS[@]}")
    fi

    if [ -n "$ORIGINAL_VBMETA_RELEASE_STRING" ]; then
        CMD+=(--internal_release_string "$ORIGINAL_VBMETA_RELEASE_STRING")
    fi

    APPEND_ARGS_FROM_STRING CMD "$TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS"

    LOG "- Creating vbmeta.img"
    LOG_PARTITION_SET "Direct descriptor images" "$DIRECT_DESCRIPTOR_IMAGES"
    LOG_PARTITION_SET "Active chain partitions" "$ACTIVE_CHAIN_PARTITIONS"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    if [ -n "$ORIGINAL_VBMETA_TRAILER_PATH" ] && [ -f "$ORIGINAL_VBMETA_TRAILER_PATH" ]; then
        # The preserved Samsung trailer is outside the AVB blocks generated by
        # avbtool, so append it after the signed vbmeta payload is complete.
        LOG "- Appending original vbmeta trailer for Samsung compatibility: marker=$ORIGINAL_VBMETA_TRAILER_MARKER size=$(FORMAT_SIZE "$ORIGINAL_VBMETA_TRAILER_SIZE")"
        cat "$ORIGINAL_VBMETA_TRAILER_PATH" >> "$TMP_IMG_DIR/vbmeta.img" || exit 1
    fi
    DUMP_AVB_INFO_IMAGE "$TMP_IMG_DIR/vbmeta.img" "vbmeta.img"
}

MAKE_VBMETA_SAMSUNG()
{
    local PARTITION
    local ENTRY
    local REQUESTED_PARTITIONS="$TARGET_AVB_VBMETA_SAMSUNG_PARTITIONS"
    local CMD=()
    local DESCRIPTOR_IMAGES=""
    local ALGORITHM="${ORIGINAL_VBMETA_SAMSUNG_ALGORITHM:-$VBMETA_SIGN_ALGORITHM}"
    local ROLLBACK_INDEX="$TARGET_AVB_ROLLBACK_INDEX"
    local ROLLBACK_INDEX_LOCATION="${ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX_LOCATION:-$TARGET_AVB_ROLLBACK_INDEX_LOCATION}"
    local RELEASE_STRING="${ORIGINAL_VBMETA_SAMSUNG_RELEASE_STRING:-}"

    VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS=""

    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ]; then
        LOG "- Skipping vbmeta_samsung.img because partition descriptors are disabled"
        return 0
    fi

    # vbmeta_samsung mirrors a stock subset of descriptors already present in
    # normal vbmeta; missing descriptor images are skipped instead of invented.
    for PARTITION in $REQUESTED_PARTITIONS; do
        for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
            case "$(basename "$ENTRY")" in
                "$PARTITION.img" | "$PARTITION.bin" | "$PARTITION")
                    APPEND_UNIQUE "DESCRIPTOR_IMAGES" "$ENTRY"
                    APPEND_UNIQUE "VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS" "$PARTITION"
                    break
                    ;;
            esac
        done

        if ! LIST_HAS_ITEM "$PARTITION" "$VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS"; then
            LOGW "Skipping vbmeta_samsung descriptor for $PARTITION because it is not included in the normal vbmeta descriptor set"
        fi
    done

    if [ -z "$DESCRIPTOR_IMAGES" ]; then
        LOGW "No descriptor images available for vbmeta_samsung.img; skipping"
        return 0
    fi

    CMD=(
        make_vbmeta_image
        --output "$TMP_IMG_DIR/vbmeta_samsung.img"
        --algorithm "$ALGORITHM"
        --rollback_index "$ROLLBACK_INDEX"
        --rollback_index_location "$ROLLBACK_INDEX_LOCATION"
        --key "$VBMETA_SIGN_KEY_PATH"
    )

    for ENTRY in $DESCRIPTOR_IMAGES; do
        CMD+=(--include_descriptors_from_image "$ENTRY")
    done

    for ENTRY in $ORIGINAL_VBMETA_SAMSUNG_PROPS; do
        CMD+=(--prop "${ENTRY%%=*}:${ENTRY#*=}")
    done

    if [ -n "$RELEASE_STRING" ]; then
        CMD+=(--internal_release_string "$RELEASE_STRING")
    fi

    APPEND_ARGS_FROM_STRING CMD "$TARGET_AVB_MAKE_VBMETA_SAMSUNG_IMAGE_ARGS"

    LOG "- Creating vbmeta_samsung.img"
    LOG_PARTITION_SET "vbmeta_samsung requested partitions" "$REQUESTED_PARTITIONS"
    LOG_PARTITION_SET "vbmeta_samsung descriptor partitions" "$VBMETA_SAMSUNG_DESCRIPTOR_PARTITIONS"
    LOG_PARTITION_SET "vbmeta_samsung descriptor images" "$DESCRIPTOR_IMAGES"
    RUN_AVBTOOL "${CMD[@]}" || exit 1
    if [ -n "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH" ] && [ -f "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH" ]; then
        LOG "- Appending original vbmeta_samsung trailer for Samsung compatibility: marker=$ORIGINAL_VBMETA_SAMSUNG_TRAILER_MARKER size=$(FORMAT_SIZE "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_SIZE")"
        cat "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH" >> "$TMP_IMG_DIR/vbmeta_samsung.img" || exit 1
    fi
    DUMP_AVB_INFO_IMAGE "$TMP_IMG_DIR/vbmeta_samsung.img" "vbmeta_samsung.img"
}

VERIFY_SIGNED_AVB()
{
    local VERIFY_DIR="$STAGING_DIR/verify"
    local ENTRY
    local PARTITION
    local LOCATION
    local VERIFY_CMD=()
    local PUBLIC_KEY_BLOB=""
    local SOURCE_PATH=""

    rm -rf "$VERIFY_DIR"
    mkdir -p "$VERIFY_DIR"

    # avbtool verify_image resolves included descriptors by partition filename,
    # so the verification dir mirrors the names a device would load.
    SOURCE_PATH="$(GET_ABSOLUTE_PATH "$TMP_IMG_DIR/vbmeta.img")"
    ln -sf "$SOURCE_PATH" "$VERIFY_DIR/vbmeta.img"
    if [ -f "$TMP_IMG_DIR/vbmeta_samsung.img" ]; then
        SOURCE_PATH="$(GET_ABSOLUTE_PATH "$TMP_IMG_DIR/vbmeta_samsung.img")"
        ln -sf "$SOURCE_PATH" "$VERIFY_DIR/vbmeta_samsung.img"
    fi

    for PARTITION in $SIGNED_PARTITIONS; do
        [ -f "$TMP_IMG_DIR/$PARTITION.img" ] || continue
        SOURCE_PATH="$(GET_ABSOLUTE_PATH "$TMP_IMG_DIR/$PARTITION.img")"
        ln -sf "$SOURCE_PATH" "$VERIFY_DIR/$PARTITION.img"
        ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$TMP_IMG_DIR/$PARTITION.img" "$PARTITION.img"
    done

    for ENTRY in $DIRECT_DESCRIPTOR_IMAGES; do
        PARTITION="$(basename "$ENTRY")"
        [ -f "$ENTRY" ] || continue
        if [ ! -e "$VERIFY_DIR/$PARTITION" ]; then
            SOURCE_PATH="$(GET_ABSOLUTE_PATH "$ENTRY")"
            ln -sf "$SOURCE_PATH" "$VERIFY_DIR/$PARTITION"
        fi
        ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$ENTRY" "$PARTITION"
    done

    ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$TMP_IMG_DIR/vbmeta.img" "vbmeta.img"

    VERIFY_CMD=(
        verify_image
        --image "$VERIFY_DIR/vbmeta.img"
        --key "$VBMETA_SIGN_KEY_PATH"
    )

    for ENTRY in $ACTIVE_CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        LOCATION="${ENTRY#*=}"
        RESOLVE_PARTITION_SIGNING_CONFIG "$PARTITION" "$(GET_SIGN_KIND "$PARTITION")"
        PUBLIC_KEY_BLOB="$(GET_CHAIN_PUBLIC_KEY_BLOB "$PARTITION" "$PARTITION_SIGN_KEY_PATH")"
        VERIFY_CMD+=(--expected_chain_partition "${PARTITION}:${LOCATION}:$PUBLIC_KEY_BLOB")
    done

    LOG "- Verifying top-level vbmeta image"
    RUN_AVBTOOL "${VERIFY_CMD[@]}" || exit 1

    if [ -f "$TMP_IMG_DIR/vbmeta_samsung.img" ]; then
        ASSERT_IMAGE_VBMETA_FLAGS_ZERO "$TMP_IMG_DIR/vbmeta_samsung.img" "vbmeta_samsung.img"
        LOG "- Verifying vbmeta_samsung image"
        RUN_AVBTOOL verify_image \
            --image "$VERIFY_DIR/vbmeta_samsung.img" \
            --key "$VBMETA_SIGN_KEY_PATH" || exit 1
    fi

    for ENTRY in $ACTIVE_CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        RESOLVE_PARTITION_SIGNING_CONFIG "$PARTITION" "$(GET_SIGN_KIND "$PARTITION")"
        LOG "- Verifying chained vbmeta image: $PARTITION.img"
        RUN_AVBTOOL verify_image \
            --image "$VERIFY_DIR/$PARTITION.img" \
            --key "$PARTITION_SIGN_KEY_PATH" || exit 1
    done
}

PRINT_KEY_SUMMARY()
{
    local CURRENT_LABEL=""
    local PRIVATE_KEY=""
    local PUBLIC_KEY=""
    local DIGEST=""
    local ALGORITHM=""

    [ -f "$KEY_EXPORT_REPORT" ] || return 0

    LOG "- AVB public key blobs exported for custom key setup:"
    while IFS='=' read -r KEY VALUE; do
        case "$KEY" in
            "label")
                CURRENT_LABEL="$VALUE"
                ;;
            "algorithm")
                ALGORITHM="$VALUE"
                ;;
            "private_key")
                PRIVATE_KEY="$VALUE"
                ;;
            "public_key_blob")
                PUBLIC_KEY="$VALUE"
                ;;
            "public_key_sha256")
                DIGEST="$VALUE"
                LOG "  * $CURRENT_LABEL: alg=$ALGORITHM key=$PRIVATE_KEY blob=$PACK_DIR/$PUBLIC_KEY sha256=$DIGEST"
                ;;
        esac
    done < "$KEY_EXPORT_REPORT"
}
