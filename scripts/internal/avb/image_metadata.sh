DUMP_AVB_INFO_IMAGE()
{
    local IMAGE="$1"
    local LABEL="$2"

    IS_AVB_DEBUG_ENABLED || return 0
    [ -f "$IMAGE" ] || return 0

    AVB_DEBUG_LOG "avbtool info_image for ${LABEL:-$(basename "$IMAGE")}:"
    RUN_AVBTOOL info_image --image "$IMAGE" >&2 || exit 1
}

GET_ABSOLUTE_PATH()
{
    local PATH_VALUE="$1"

    if command -v realpath &> /dev/null; then
        realpath "$PATH_VALUE"
    else
        (
            cd "$(dirname "$PATH_VALUE")" || exit 1
            printf '%s/%s\n' "$(pwd -P)" "$(basename "$PATH_VALUE")"
        )
    fi
}

GET_METADATA_VALUE()
{
    local FILE="$1"
    local KEY="$2"

    [ -f "$FILE" ] || return 0

    sed -n "s/^$KEY=//p" "$FILE" | head -n 1
}

ROUND_UP_TO_4K()
{
    local VALUE="$1"

    echo "$((((VALUE + 4095) / 4096) * 4096))"
}

FORMAT_SIZE()
{
    local VALUE="$1"

    if command -v numfmt &> /dev/null; then
        printf '%s (%s)' "$VALUE" "$(numfmt --to=iec --suffix=B "$VALUE")"
    else
        printf '%s bytes' "$VALUE"
    fi
}

GET_EXPLICIT_PARTITION_SIZE()
{
    local PARTITION="$1"
    local VAR_NAME
    local VALUE

    VAR_NAME="TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE"
    eval "VALUE=\${$VAR_NAME:-}"

    [ -n "$VALUE" ] && [ "$VALUE" != "none" ] && echo "$VALUE"
}

GET_STOCK_IMAGE_PATH()
{
    local PARTITION="$1"
    local CANDIDATE
    local CANDIDATES=()

    case "$PARTITION" in
        "dtb")
            CANDIDATES+=(
                "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/dtb.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/dt.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/dtb.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/dt.img"
            )
            ;;
        "boot" | "dtbo" | "init_boot" | "vendor_boot" | "recovery")
            CANDIDATES+=(
                "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/$PARTITION.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/$PARTITION.img"
            )
            ;;
        *)
            CANDIDATES+=(
                "$FW_DIR/$TARGET_FIRMWARE_PATH/$PARTITION.img"
                "$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/$PARTITION.img"
            )
            ;;
    esac

    for CANDIDATE in "${CANDIDATES[@]}"; do
        [ -f "$CANDIDATE" ] && echo "$CANDIDATE" && return 0
    done
}

GET_METADATA_PARTITION_SIZE()
{
    local PARTITION="$1"
    local VALUE=""

    case "$PARTITION" in
        "boot" | "dtbo" | "init_boot" | "vendor_boot" | "recovery")
            VALUE="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/$PARTITION.img_metadata.txt" "partition_size")"
            ;;
        *)
            VALUE="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/$PARTITION.img_metadata.txt" "partition_size")"
            [ -z "$VALUE" ] && VALUE="$(GET_METADATA_VALUE "$FW_DIR/$TARGET_FIRMWARE_PATH/os_partitions_metadata.txt" "${PARTITION}_size")"
            ;;
    esac

    [ -n "$VALUE" ] && echo "$VALUE"
}

GET_STOCK_IMAGE_PARTITION_SIZE()
{
    local PARTITION="$1"
    local IMAGE

    IMAGE="$(GET_STOCK_IMAGE_PATH "$PARTITION")"
    [ -f "$IMAGE" ] || return 0

    GET_IMAGE_SIZE "$IMAGE"
}

GET_STOCK_FIRMWARE_IMAGE_PATH()
{
    local PARTITION="$1"
    local IMAGE=""

    IMAGE="$(GET_STOCK_IMAGE_PATH "$PARTITION" || true)"
    if [ -n "$IMAGE" ] && [ -f "$IMAGE" ]; then
        echo "$IMAGE"
        return 0
    fi

    GET_FIRMWARE_DESCRIPTOR_SOURCE_PATH "$PARTITION" "true"
}

GET_STOCK_FIRMWARE_IMAGE_PARTITION_SIZE()
{
    local PARTITION="$1"
    local IMAGE=""

    IMAGE="$(GET_STOCK_FIRMWARE_IMAGE_PATH "$PARTITION" || true)"
    [ -n "$IMAGE" ] && [ -f "$IMAGE" ] || return 0

    GET_IMAGE_SIZE "$IMAGE"
}

GET_EXISTING_AVB_IMAGE_PARTITION_SIZE()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"

    [ -f "$IMAGE" ] || return 0
    RUN_AVBTOOL info_image --image "$IMAGE" &> /dev/null || return 0

    GET_IMAGE_SIZE "$IMAGE"
}

ESTIMATE_PARTITION_SIZE_FROM_IMAGE_PATH()
{
    local IMAGE="$1"
    local KIND="$2"
    local IMAGE_SIZE
    local EXTRA_SIZE

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"

    # Without exact partition metadata, reserve enough room for the footer and
    # hashtree/FEC growth so calc_max_image_size has a plausible upper bound.
    if [ "$KIND" = "hashtree" ]; then
        EXTRA_SIZE="$((IMAGE_SIZE / 64))"
        [ "$EXTRA_SIZE" -lt $((16 * 1024 * 1024)) ] && EXTRA_SIZE=$((16 * 1024 * 1024))
    else
        EXTRA_SIZE=$((4 * 1024 * 1024))
    fi

    echo "$(ROUND_UP_TO_4K "$((IMAGE_SIZE + EXTRA_SIZE))")"
}

IS_DYNAMIC_AVB_PARTITION()
{
    local PARTITION="$1"

    [ "${TARGET_SUPER_PARTITION_SIZE:-0}" -ne 0 ] || return 1

    case "$PARTITION" in
        "system" | "vendor" | "product" | "system_ext" | "odm" | "vendor_dlkm" | "odm_dlkm" | "system_dlkm")
            return 0
            ;;
    esac

    return 1
}

ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE()
{
    local PARTITION="$1"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local KIND="$2"

    [ -f "$IMAGE" ] || return 0

    ESTIMATE_PARTITION_SIZE_FROM_IMAGE_PATH "$IMAGE" "$KIND"
}

CALCULATE_AVB_MAX_IMAGE_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local CMD=()
    local OUTPUT=""
    local STDERR_FILE="$STAGING_DIR/calc_max_${PARTITION}_${KIND}.stderr"
    local CMD_STRING=""
    local ARG

    # Ask official avbtool for payload capacity instead of duplicating its
    # footer/hashtree/FEC sizing rules in shell.
    BUILD_SIGN_IMAGE_CMD CMD "" "$PARTITION" "$KIND" "$PARTITION_SIZE" "calc"
    AVB_DEBUG_LOG "Calculating AVB max image size for $PARTITION ($KIND): $(FORMAT_COMMAND "${AVBTOOL_CMD[@]}" "${CMD[@]}")"

    rm -f "$STDERR_FILE"
    OUTPUT="$(RUN_AVBTOOL "${CMD[@]}" 2> "$STDERR_FILE" | tail -n 1 | tr -d '[:space:]')" || true

    if ! [[ "$OUTPUT" =~ ^[0-9]+$ ]]; then
        for ARG in "${AVBTOOL_CMD[@]}" "${CMD[@]}"; do
            if [ -n "$CMD_STRING" ]; then
                CMD_STRING+=" "
            fi
            CMD_STRING+="$(printf '%q' "$ARG")"
        done

        if [ -s "$STDERR_FILE" ]; then
            LOGE "Official AVB calc_max_image_size failed for $PARTITION ($KIND): $(tr '\n' ' ' < "$STDERR_FILE" | sed 's/[[:space:]]\\+/ /g')"
        else
            LOGE "Official AVB calc_max_image_size returned no numeric output for $PARTITION ($KIND)"
        fi
        LOGE "Failing AVB command: $CMD_STRING"
        return 1
    fi

    AVB_DEBUG_LOG "Calculated AVB max image size for $PARTITION ($KIND): $OUTPUT"

    echo "$OUTPUT"
}

CALCULATE_MIN_AVB_PARTITION_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local IMAGE_SIZE
    local LOWER_BOUND
    local UPPER_BOUND
    local MID
    local MAX_IMAGE_SIZE

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"
    LOWER_BOUND="$IMAGE_SIZE"
    UPPER_BOUND="$(ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE "$PARTITION" "$KIND")"
    [ -n "$UPPER_BOUND" ] || return 1
    UPPER_BOUND="$(ROUND_UP_TO_4K "$UPPER_BOUND")"
    [ "$UPPER_BOUND" -lt "$LOWER_BOUND" ] && UPPER_BOUND="$LOWER_BOUND"

    while true; do
        MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$UPPER_BOUND")" || return 1
        [ "$MAX_IMAGE_SIZE" -ge "$IMAGE_SIZE" ] && break

        UPPER_BOUND="$(ROUND_UP_TO_4K "$((UPPER_BOUND * 2))")"
        [ "$UPPER_BOUND" -gt $((128 * 1024 * 1024 * 1024)) ] && return 1
    done

    while [ "$LOWER_BOUND" -lt "$UPPER_BOUND" ]; do
        MID="$((((LOWER_BOUND + UPPER_BOUND) / 2) / 4096 * 4096))"
        # Bounds are 4 KiB-aligned. If the midpoint rounds back to the current
        # lower bound, there is no aligned candidate left between the bounds.
        [ "$MID" -le "$LOWER_BOUND" ] && break

        MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$MID")" || return 1
        if [ "$MAX_IMAGE_SIZE" -ge "$IMAGE_SIZE" ]; then
            UPPER_BOUND="$MID"
        else
            LOWER_BOUND="$(ROUND_UP_TO_4K "$((MID + 1))")"
        fi
    done

    echo "$UPPER_BOUND"
}

CAN_SIGN_IMAGE_WITH_PARTITION_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local IMAGE="$TMP_IMG_DIR/$PARTITION.img"
    local IMAGE_SIZE
    local MAX_IMAGE_SIZE

    [ -f "$IMAGE" ] || return 0

    IMAGE_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || return 1
    IMAGE_SIZE="$(ROUND_UP_TO_4K "$IMAGE_SIZE")"

    MAX_IMAGE_SIZE="$(CALCULATE_AVB_MAX_IMAGE_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE")" || return 1
    [ "$MAX_IMAGE_SIZE" -ge "$IMAGE_SIZE" ]
}

RESOLVE_SIGN_PARTITION_SIZE()
{
    local PARTITION="$1"
    local KIND="$2"
    local PARTITION_SIZE="$3"
    local VALUE
    local LIMIT=0
    local ATTEMPTS=0

    if CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "$KIND" "$PARTITION_SIZE"; then
        echo "$PARTITION_SIZE"
        return 0
    fi

    if IS_DYNAMIC_AVB_PARTITION "$PARTITION"; then
        # Dynamic partition metadata can absorb larger logical sizes, so grow in
        # bounded steps before falling back to the exact minimum calculation.
        LIMIT="${TARGET_SUPER_GROUP_SIZE:-0}"
        [ "$LIMIT" -le 0 ] && LIMIT="${TARGET_SUPER_PARTITION_SIZE:-0}"
        VALUE="$PARTITION_SIZE"

        while [ "$ATTEMPTS" -lt 16 ]; do
            ATTEMPTS="$((ATTEMPTS + 1))"
            VALUE="$(ROUND_UP_TO_4K "$((VALUE + (64 * 1024 * 1024)))")"

            if [ "$LIMIT" -gt 0 ] && [ "$VALUE" -gt "$LIMIT" ]; then
                VALUE="$LIMIT"
            fi

            if CAN_SIGN_IMAGE_WITH_PARTITION_SIZE "$PARTITION" "$KIND" "$VALUE"; then
                LOGW "Increasing AVB partition size for dynamic partition $PARTITION: $PARTITION_SIZE -> $VALUE" >&2
                echo "$VALUE"
                return 0
            fi

            if [ "$LIMIT" -gt 0 ] && [ "$VALUE" -ge "$LIMIT" ]; then
                break
            fi
        done

        VALUE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND")"
        if [ -n "$VALUE" ] && [ "$VALUE" -gt "$PARTITION_SIZE" ]; then
            LOGW "Increasing AVB partition size for dynamic partition $PARTITION: $PARTITION_SIZE -> $VALUE" >&2
            echo "$VALUE"
            return 0
        fi
    fi

    echo "$PARTITION_SIZE"
}

GET_PARTITION_SIZE_INFO()
{
    local PARTITION="$1"
    local VALUE=""
    local KIND

    # Exact metadata wins. Built-image estimates are a last resort because AVB
    # footers must be written with the final flash partition size.
    VALUE="$(GET_EXPLICIT_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE|explicit" && return 0

    VALUE="$(GET_METADATA_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE|metadata" && return 0

    if ! IS_DYNAMIC_AVB_PARTITION "$PARTITION"; then
        VALUE="$(GET_STOCK_FIRMWARE_IMAGE_PARTITION_SIZE "$PARTITION")"
        [ -n "$VALUE" ] && echo "$VALUE|stock_firmware_image_size" && return 0
    fi

    VALUE="$(GET_EXISTING_AVB_IMAGE_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE|existing_avb_image_size" && return 0

    VALUE="$(GET_STOCK_IMAGE_PARTITION_SIZE "$PARTITION")"
    [ -n "$VALUE" ] && echo "$VALUE|stock_image_size" && return 0

    KIND="$(GET_SIGN_KIND "$PARTITION")"
    if IS_DYNAMIC_AVB_PARTITION "$PARTITION"; then
        LOG "- Resolving dynamic AVB partition size for $PARTITION from the built image" >&2

        VALUE="$(ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE "$PARTITION" "$KIND")"
        if [ -n "$VALUE" ]; then
            LOGW "Estimated AVB partition size for dynamic partition $PARTITION: $VALUE" >&2
            echo "$VALUE|dynamic_estimate"
            return 0
        fi

        VALUE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND")"
        if [ -n "$VALUE" ]; then
            LOGW "Calculated AVB partition size for dynamic partition $PARTITION from the built image: $VALUE" >&2
            echo "$VALUE|dynamic_calculated"
            return 0
        fi
    fi

    VALUE="$(ESTIMATE_PARTITION_SIZE_FROM_BUILT_IMAGE "$PARTITION" "$KIND")"
    if [ -n "$VALUE" ]; then
        LOGW "Estimated AVB partition size for $PARTITION from the built image: $VALUE" >&2
        echo "$VALUE|built_image_estimate"
        return 0
    fi

    VALUE="$(CALCULATE_MIN_AVB_PARTITION_SIZE "$PARTITION" "$KIND")"
    if [ -n "$VALUE" ]; then
        LOGW "Calculated AVB partition size for $PARTITION from the built image: $VALUE" >&2
        echo "$VALUE|built_image_calculated"
        return 0
    fi

    return 1
}

ASSERT_FIXED_CHAIN_PARTITION_SIZE_SOURCE()
{
    local PARTITION="$1"
    local SOURCE="$2"

    [ -n "$(GET_CHAIN_LOCATION "$PARTITION")" ] || return 0
    IS_DYNAMIC_AVB_PARTITION "$PARTITION" && return 0

    # Fixed chained partitions publish a public-key descriptor in top-level
    # vbmeta, so do not sign them from guessed partition geometry.
    case "$SOURCE" in
        "built_image_estimate" | "built_image_calculated")
            LOGE "Unable to safely sign chained fixed partition $PARTITION from a guessed size. Re-extract firmware metadata or set TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE."
            exit 1
            ;;
    esac
}

GET_SIGN_KIND()
{
    local PARTITION="$1"

    if LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
        echo "hashtree"
    elif LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS"; then
        echo "hash"
    else
        echo "hash"
    fi
}

BUILD_SIGN_IMAGE_CMD()
{
    local ARRAY_NAME="$1"
    local IMAGE="$2"
    local PARTITION="$3"
    local KIND="$4"
    local PARTITION_SIZE="$5"
    local MODE="$6"
    local BUILT_CMD=()

    RESOLVE_PARTITION_SIGNING_CONFIG "$PARTITION" "$KIND"

    if [ "$KIND" = "hashtree" ]; then
        BUILT_CMD=(add_hashtree_footer)
    else
        BUILT_CMD=(add_hash_footer)
    fi

    if [ "$MODE" = "calc" ]; then
        BUILT_CMD+=(--calc_max_image_size)
    else
        BUILT_CMD+=(--image "$IMAGE")
    fi

    BUILT_CMD+=(
        --partition_name "$PARTITION"
        --partition_size "$PARTITION_SIZE"
        --hash_algorithm "$PARTITION_SIGN_HASH_ALGORITHM"
        --rollback_index "$PARTITION_SIGN_ROLLBACK_INDEX"
        --rollback_index_location "$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION"
    )

    if [ "$PARTITION_SIGN_ALGORITHM" = "NONE" ]; then
        BUILT_CMD+=(--algorithm NONE)
    else
        BUILT_CMD+=(--algorithm "$PARTITION_SIGN_ALGORITHM" --key "$PARTITION_SIGN_KEY_PATH")
    fi

    [ "$PARTITION_SIGN_DO_NOT_USE_AB" = "true" ] && BUILT_CMD+=(--do_not_use_ab)
    APPEND_ARGS_FROM_STRING BUILT_CMD "$PARTITION_SIGN_EXTRA_ARGS"

    eval "$ARRAY_NAME=(\"\${BUILT_CMD[@]}\")"
}
