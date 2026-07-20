SET_PARTITION_SIGN_KIND()
{
    local PARTITION="$1"
    local KIND="$2"

    REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
    REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"

    if [ "$KIND" = "hashtree" ]; then
        APPEND_UNIQUE "HASHTREE_PARTITIONS" "$PARTITION"
    else
        APPEND_UNIQUE "HASH_PARTITIONS" "$PARTITION"
    fi
}

APPEND_ARGS_FROM_STRING()
{
    local ARRAY_NAME="$1"
    local VALUE="$2"
    local PARSED_ARGS=()

    [ -n "$VALUE" ] || return 0

    # Values come from trusted target config shell variables and may rely on
    # normal shell quoting semantics.
    eval "PARSED_ARGS=( $VALUE )"
    eval "$ARRAY_NAME+=(\"\${PARSED_ARGS[@]}\")"
}

GET_ENV_VALUE()
{
    local VAR_NAME="$1"
    local VALUE=""

    eval "VALUE=\${$VAR_NAME:-}"
    [ -n "$VALUE" ] && [ "$VALUE" != "none" ] && echo "$VALUE"
}

GET_PARTITION_VAR_VALUE()
{
    local PARTITION="$1"
    local SUFFIX="$2"
    local VAR_NAME

    # Per-partition overrides use TARGET_AVB_<PARTITION>_<SUFFIX>, with hyphens
    # normalized for shell variable names.
    VAR_NAME="TARGET_AVB_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_${SUFFIX}"
    GET_ENV_VALUE "$VAR_NAME"
}

GET_CHAIN_LOCATION()
{
    local PARTITION="$1"
    local VALUE=""

    VALUE="$(GET_KV_VALUE "$PARTITION" "$CHAIN_PARTITIONS")"
    [ -n "$VALUE" ] && echo "$VALUE"
}

IS_EXCLUDED_AVB_PARTITION()
{
    local PARTITION="$1"

    LIST_HAS_ITEM "$PARTITION" "$EXCLUDED_VBMETA_PARTITIONS"
}

IS_AVB_DEBUG_ENABLED()
{
    [ "${DEBUG:-false}" = "true" ]
}

AVB_DEBUG_LOG()
{
    local INDENT="${INDENT_LEVEL:=0}"

    IS_AVB_DEBUG_ENABLED || return 0
    printf "%*s- [AVB debug] %s\n" "$INDENT" "" "$1" >&2
}

FORMAT_COMMAND()
{
    local OUTPUT=""
    local ARG

    for ARG in "$@"; do
        if [ -n "$OUTPUT" ]; then
            OUTPUT+=" "
        fi
        OUTPUT+="$(printf '%q' "$ARG")"
    done

    printf '%s' "$OUTPUT"
}

LOG_PARTITION_SET()
{
    local LABEL="$1"
    local VALUE="$2"

    AVB_DEBUG_LOG "$LABEL: ${VALUE:-<empty>}"
}

INIT_DEFAULTS()
{
    TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT="${TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT:-true}"
    TARGET_AVB_KEY_PATH="${TARGET_AVB_KEY_PATH:-$DEFAULT_CUSTOM_AVB_KEY_PATH}"
    case "$TARGET_AVB_KEY_PATH" in
        "auto_aosp_platform" | "$OUT_DIR/security/aosp_platform_avb.pem" | */aosp_platform_avb.pem)
            LOGW "AOSP AVB key fallback is no longer used. Switching to generated custom AVB key at $DEFAULT_CUSTOM_AVB_KEY_PATH"
            TARGET_AVB_KEY_PATH="$DEFAULT_CUSTOM_AVB_KEY_PATH"
            ;;
    esac
    if [ -z "${TARGET_AVB_ALGORITHM:-}" ] || \
            { [ "$TARGET_AVB_KEY_PATH" = "$DEFAULT_CUSTOM_AVB_KEY_PATH" ] && [ "$TARGET_AVB_ALGORITHM" = "SHA256_RSA2048" ]; }; then
        TARGET_AVB_ALGORITHM="SHA256_RSA4096"
    fi
    TARGET_AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-$UPSTREAM_AVBTOOL_PATH}"
    TARGET_AVBTOOL_PYTHON="${TARGET_AVBTOOL_PYTHON:-none}"
    TARGET_AVB_LOW_SECURITY="${TARGET_AVB_LOW_SECURITY:-false}"
    TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS="${TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS:-true}"
    TARGET_AVB_HASH_PARTITIONS="${TARGET_AVB_HASH_PARTITIONS:-}"
    TARGET_AVB_HASHTREE_PARTITIONS="${TARGET_AVB_HASHTREE_PARTITIONS:-}"
    TARGET_AVB_CHAIN_PARTITIONS="${TARGET_AVB_CHAIN_PARTITIONS:-}"
    TARGET_AVB_ORIGINAL_VBMETA_PATH="${TARGET_AVB_ORIGINAL_VBMETA_PATH:-none}"
    TARGET_AVB_ALLOW_HASHTREE_FALLBACK="${TARGET_AVB_ALLOW_HASHTREE_FALLBACK:-false}"
    TARGET_AVB_ROLLBACK_INDEX="${TARGET_AVB_ROLLBACK_INDEX:-0}"
    TARGET_AVB_ROLLBACK_INDEX_LOCATION="${TARGET_AVB_ROLLBACK_INDEX_LOCATION:-0}"
    TARGET_AVB_HASH_ALGORITHM="${TARGET_AVB_HASH_ALGORITHM:-sha256}"
    TARGET_AVB_VBMETA_FLAGS="${TARGET_AVB_VBMETA_FLAGS:-}"
    if [ -z "$TARGET_AVB_VBMETA_FLAGS" ]; then
        TARGET_AVB_VBMETA_FLAGS="0"
    fi
    TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS="${TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS:-}"
    TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS="${TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS:-}"
    TARGET_AVB_FIRMWARE_IMAGE_MAP="${TARGET_AVB_FIRMWARE_IMAGE_MAP:-}"
    TARGET_AVB_USE_ORIGINAL_VBMETA_PROPS="${TARGET_AVB_USE_ORIGINAL_VBMETA_PROPS:-true}"
    TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES="${TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES:-true}"
    TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH="${TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH:-none}"
    TARGET_AVB_VBMETA_SAMSUNG_PARTITIONS="${TARGET_AVB_VBMETA_SAMSUNG_PARTITIONS:-odm product system vendor}"
    TARGET_AVB_MAKE_VBMETA_SAMSUNG_IMAGE_ARGS="${TARGET_AVB_MAKE_VBMETA_SAMSUNG_IMAGE_ARGS:-}"

    if [ "$TARGET_AVB_LOW_SECURITY" != "true" ] && [ "$TARGET_AVB_LOW_SECURITY" != "false" ]; then
        LOGE "TARGET_AVB_LOW_SECURITY must be true or false (got: $TARGET_AVB_LOW_SECURITY)"
        exit 1
    fi
    if ! [[ "$TARGET_AVB_VBMETA_FLAGS" =~ ^[0-9]+$ ]]; then
        LOGE "TARGET_AVB_VBMETA_FLAGS must be a non-negative integer (got: $TARGET_AVB_VBMETA_FLAGS)"
        exit 1
    fi
    if [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ] && [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "false" ]; then
        LOGW "Invalid TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS: $TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS (expected true|false). Using true."
        TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS="true"
    fi
    # Low-security mode avoids partition descriptors instead of relying on
    # non-zero vbmeta flags; verification later rejects those flags outright.
    if $TARGET_AVB_LOW_SECURITY && [ "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "false" ]; then
        LOGW "Disabling vbmeta partition descriptors for AVB low-security mode"
        TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS="false"
    fi
    if [ "$TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES" != "true" ] && [ "$TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES" != "false" ]; then
        LOGW "Invalid TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES: $TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES (expected true|false). Using true."
        TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES="true"
    fi
}

GET_FALLBACK_HASH_PARTITIONS()
{
    echo "boot vendor_boot init_boot recovery"
}

GET_FALLBACK_HASHTREE_PARTITIONS()
{
    echo "system vendor product odm system_ext vendor_dlkm odm_dlkm system_dlkm prism optics"
}

GET_FALLBACK_CHAIN_PARTITIONS()
{
    echo "dtbo=7 prism=12 optics=13"
}

GET_ORIGINAL_VBMETA_SAMSUNG_PATH()
{
    if [ "$TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH" != "none" ] && [ -f "$TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH" ]; then
        echo "$TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH"
    elif [ -f "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta_samsung.img" ]; then
        echo "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta_samsung.img"
    fi
}

GET_ORIGINAL_VBMETA_PATH()
{
    if [ "$TARGET_AVB_ORIGINAL_VBMETA_PATH" != "none" ] && [ -f "$TARGET_AVB_ORIGINAL_VBMETA_PATH" ]; then
        echo "$TARGET_AVB_ORIGINAL_VBMETA_PATH"
    elif [ -f "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta.img" ]; then
        echo "$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta.img"
    elif [ -f "$SRC_DIR/../vbmeta.img" ]; then
        echo "$SRC_DIR/../vbmeta.img"
    fi
}

PARSE_ORIGINAL_VBMETA_LAYOUT()
{
    local ORIGINAL_VBMETA
    local KIND
    local KEY
    local VALUE
    local TRAILER_INFO=""
    local TRAILER_OFFSET=""
    local TRAILER_SIZE=""
    local TRAILER_MARKER=""

    $TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT || return 0

    ORIGINAL_VBMETA="$(GET_ORIGINAL_VBMETA_PATH)"
    [ -f "$ORIGINAL_VBMETA" ] || return 0
    [ -n "$AVB_PYTHON_BIN" ] || return 0
    [ -f "$AVBTOOL_PATH" ] || return 0
    : > "$ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE"

    # Use avbtool as the source of truth so rebuilt vbmeta keeps the stock
    # descriptor topology when target config only provides overrides.
    DUMP_AVB_INFO_IMAGE "$ORIGINAL_VBMETA" "original vbmeta"

    while IFS=$'\t' read -r KIND KEY VALUE; do
        case "$KIND" in
            "meta_algorithm")
                ORIGINAL_VBMETA_ALGORITHM="$KEY"
                ;;
            "meta_rollback_index")
                ORIGINAL_VBMETA_ROLLBACK_INDEX="$KEY"
                ;;
            "meta_rollback_index_location")
                ORIGINAL_VBMETA_ROLLBACK_INDEX_LOCATION="$KEY"
                ;;
            "meta_release_string")
                ORIGINAL_VBMETA_RELEASE_STRING="$KEY"
                ;;
            "prop")
                APPEND_UNIQUE "ORIGINAL_VBMETA_PROPS" "$KEY=$VALUE"
                ;;
            "hash")
                APPEND_UNIQUE "ORIGINAL_HASH_PARTITIONS" "$KEY"
                ;;
            "hashtree")
                APPEND_UNIQUE "ORIGINAL_HASHTREE_PARTITIONS" "$KEY"
                ;;
            "chain")
                APPEND_UNIQUE "ORIGINAL_CHAIN_PARTITIONS" "$KEY=$VALUE"
                ;;
            "kernel_cmdline")
                printf '%s\t%s\n' "$KEY" "$VALUE" >> "$ORIGINAL_VBMETA_KERNEL_CMDLINES_FILE"
                ORIGINAL_VBMETA_KERNEL_CMDLINE_COUNT="$((ORIGINAL_VBMETA_KERNEL_CMDLINE_COUNT + 1))"
                ;;
        esac
    done < <(
        "$AVB_PYTHON_BIN" "$AVB_METADATA_TOOL" \
            --avbtool "$AVBTOOL_PATH" records --image "$ORIGINAL_VBMETA"
    )

    TRAILER_INFO="$(
        "$AVB_PYTHON_BIN" "$AVB_METADATA_TOOL" \
            --avbtool "$AVBTOOL_PATH" trailer --image "$ORIGINAL_VBMETA"
    )"

    if [ -n "$TRAILER_INFO" ]; then
        TRAILER_OFFSET="$(cut -f 1 <<< "$TRAILER_INFO")"
        TRAILER_SIZE="$(cut -f 2 <<< "$TRAILER_INFO")"
        TRAILER_MARKER="$(cut -f 3 <<< "$TRAILER_INFO")"
        ORIGINAL_VBMETA_TRAILER_PATH="$STAGING_DIR/original_vbmeta_trailer.bin"
        # Samsung signer metadata is outside the AVB-authenticated image and
        # must be copied byte-for-byte after avbtool regenerates vbmeta.
        dd if="$ORIGINAL_VBMETA" of="$ORIGINAL_VBMETA_TRAILER_PATH" bs=1 skip="$TRAILER_OFFSET" count="$TRAILER_SIZE" status=none || exit 1
        ORIGINAL_VBMETA_TRAILER_SIZE="$TRAILER_SIZE"
        ORIGINAL_VBMETA_TRAILER_MARKER="$TRAILER_MARKER"
        LOG "- Preserving original vbmeta trailer: marker=$ORIGINAL_VBMETA_TRAILER_MARKER size=$(FORMAT_SIZE "$ORIGINAL_VBMETA_TRAILER_SIZE")"
    fi

    LOG_PARTITION_SET "Original vbmeta props" "$ORIGINAL_VBMETA_PROPS"
    [ -n "$ORIGINAL_VBMETA_ALGORITHM" ] && AVB_DEBUG_LOG "Original vbmeta algorithm: $ORIGINAL_VBMETA_ALGORITHM"
    LOG_PARTITION_SET "Original vbmeta hash partitions" "$ORIGINAL_HASH_PARTITIONS"
    LOG_PARTITION_SET "Original vbmeta hashtree partitions" "$ORIGINAL_HASHTREE_PARTITIONS"
    LOG_PARTITION_SET "Original vbmeta chain partitions" "$ORIGINAL_CHAIN_PARTITIONS"
    AVB_DEBUG_LOG "Original vbmeta kernel cmdline descriptors: $ORIGINAL_VBMETA_KERNEL_CMDLINE_COUNT"
}

PARSE_ORIGINAL_VBMETA_SAMSUNG_LAYOUT()
{
    local ORIGINAL_VBMETA_SAMSUNG
    local KIND
    local KEY
    local VALUE
    local TRAILER_INFO=""
    local TRAILER_OFFSET=""
    local TRAILER_SIZE=""
    local TRAILER_MARKER=""
    local ORIGINAL_PARTITIONS=""

    $TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT || return 0

    ORIGINAL_VBMETA_SAMSUNG="$(GET_ORIGINAL_VBMETA_SAMSUNG_PATH)"
    [ -f "$ORIGINAL_VBMETA_SAMSUNG" ] || return 0
    [ -n "$AVB_PYTHON_BIN" ] || return 0
    [ -f "$AVBTOOL_PATH" ] || return 0

    DUMP_AVB_INFO_IMAGE "$ORIGINAL_VBMETA_SAMSUNG" "original vbmeta_samsung"

    while IFS=$'\t' read -r KIND KEY VALUE; do
        case "$KIND" in
            "meta_algorithm")
                ORIGINAL_VBMETA_SAMSUNG_ALGORITHM="$KEY"
                ;;
            "meta_rollback_index")
                ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX="$KEY"
                ;;
            "meta_rollback_index_location")
                ORIGINAL_VBMETA_SAMSUNG_ROLLBACK_INDEX_LOCATION="$KEY"
                ;;
            "meta_release_string")
                ORIGINAL_VBMETA_SAMSUNG_RELEASE_STRING="$KEY"
                ;;
            "prop")
                APPEND_UNIQUE "ORIGINAL_VBMETA_SAMSUNG_PROPS" "$KEY=$VALUE"
                ;;
            "hash" | "hashtree" | "chain")
                APPEND_UNIQUE "ORIGINAL_PARTITIONS" "$KEY"
                ;;
        esac
    done < <(
        "$AVB_PYTHON_BIN" "$AVB_METADATA_TOOL" \
            --avbtool "$AVBTOOL_PATH" records --image "$ORIGINAL_VBMETA_SAMSUNG"
    )

    TRAILER_INFO="$(
        "$AVB_PYTHON_BIN" "$AVB_METADATA_TOOL" \
            --avbtool "$AVBTOOL_PATH" trailer --image "$ORIGINAL_VBMETA_SAMSUNG"
    )"

    if [ -n "$TRAILER_INFO" ]; then
        TRAILER_OFFSET="$(cut -f 1 <<< "$TRAILER_INFO")"
        TRAILER_SIZE="$(cut -f 2 <<< "$TRAILER_INFO")"
        TRAILER_MARKER="$(cut -f 3 <<< "$TRAILER_INFO")"
        ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH="$STAGING_DIR/original_vbmeta_samsung_trailer.bin"
        # Keep the Samsung trailer separate from AVB metadata; it is appended
        # after the regenerated vbmeta_samsung payload.
        dd if="$ORIGINAL_VBMETA_SAMSUNG" of="$ORIGINAL_VBMETA_SAMSUNG_TRAILER_PATH" bs=1 skip="$TRAILER_OFFSET" count="$TRAILER_SIZE" status=none || exit 1
        ORIGINAL_VBMETA_SAMSUNG_TRAILER_SIZE="$TRAILER_SIZE"
        ORIGINAL_VBMETA_SAMSUNG_TRAILER_MARKER="$TRAILER_MARKER"
        LOG "- Preserving original vbmeta_samsung trailer: marker=$ORIGINAL_VBMETA_SAMSUNG_TRAILER_MARKER size=$(FORMAT_SIZE "$ORIGINAL_VBMETA_SAMSUNG_TRAILER_SIZE")"
    fi

    LOG_PARTITION_SET "Original vbmeta_samsung props" "$ORIGINAL_VBMETA_SAMSUNG_PROPS"
    LOG_PARTITION_SET "Original vbmeta_samsung partitions" "$ORIGINAL_PARTITIONS"
    [ -n "$ORIGINAL_VBMETA_SAMSUNG_ALGORITHM" ] && AVB_DEBUG_LOG "Original vbmeta_samsung algorithm: $ORIGINAL_VBMETA_SAMSUNG_ALGORITHM"
}

ADOPT_ORIGINAL_VBMETA_DEFAULTS()
{
    if [ -n "$ORIGINAL_VBMETA_ALGORITHM" ] && [ "$TARGET_AVB_KEY_PATH" = "$DEFAULT_CUSTOM_AVB_KEY_PATH" ] && \
            [ "$TARGET_AVB_ALGORITHM" != "$ORIGINAL_VBMETA_ALGORITHM" ]; then
        LOG "- Adopting original vbmeta signing algorithm: $ORIGINAL_VBMETA_ALGORITHM"
        TARGET_AVB_ALGORITHM="$ORIGINAL_VBMETA_ALGORITHM"
    fi

    if [ -z "${TARGET_AVB_ROLLBACK_INDEX:-}" ] && [ -n "$ORIGINAL_VBMETA_ROLLBACK_INDEX" ]; then
        TARGET_AVB_ROLLBACK_INDEX="$ORIGINAL_VBMETA_ROLLBACK_INDEX"
    fi
    if [ "$TARGET_AVB_ROLLBACK_INDEX_LOCATION" = "0" ] && [ -n "$ORIGINAL_VBMETA_ROLLBACK_INDEX_LOCATION" ]; then
        TARGET_AVB_ROLLBACK_INDEX_LOCATION="$ORIGINAL_VBMETA_ROLLBACK_INDEX_LOCATION"
    fi
}

MERGE_LAYOUT()
{
    local ENTRY
    local PARTITION
    local LOCATION

    # Start with explicit target config, then layer stock vbmeta descriptors on
    # top so unspecified partitions keep their original verification shape.
    HASH_PARTITIONS="$TARGET_AVB_HASH_PARTITIONS"
    HASHTREE_PARTITIONS="$TARGET_AVB_HASHTREE_PARTITIONS"
    CHAIN_PARTITIONS="$TARGET_AVB_CHAIN_PARTITIONS"

    # Build a signed top-level vbmeta for compatibility, but leave partition
    # images and descriptor chains untouched in low-security mode.
    if $TARGET_AVB_LOW_SECURITY; then
        LOG "- AVB low-security mode: skipping partition image footer signing and vbmeta partition descriptors"
        HASH_PARTITIONS=""
        HASHTREE_PARTITIONS=""
        CHAIN_PARTITIONS=""
        return 0
    fi

    if [ -z "$HASH_PARTITIONS$HASHTREE_PARTITIONS$CHAIN_PARTITIONS" ] && \
            [ -z "$ORIGINAL_HASH_PARTITIONS$ORIGINAL_HASHTREE_PARTITIONS$ORIGINAL_CHAIN_PARTITIONS" ]; then
        LOGW "Original vbmeta layout is unavailable; falling back to built-in AVB partition defaults"
        HASH_PARTITIONS="$(GET_FALLBACK_HASH_PARTITIONS)"
        HASHTREE_PARTITIONS="$(GET_FALLBACK_HASHTREE_PARTITIONS)"
        CHAIN_PARTITIONS="$(GET_FALLBACK_CHAIN_PARTITIONS)"
    fi

    for PARTITION in $EXCLUDED_VBMETA_PARTITIONS; do
        if LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS"; then
            LOGW "Removing $PARTITION from TARGET_AVB_HASH_PARTITIONS; verification for this partition is disabled"
            REMOVE_ITEM "HASH_PARTITIONS" "$PARTITION"
        fi
        if LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS"; then
            LOGW "Removing $PARTITION from TARGET_AVB_HASHTREE_PARTITIONS; verification for this partition is disabled"
            REMOVE_ITEM "HASHTREE_PARTITIONS" "$PARTITION"
        fi
        LOCATION="$(GET_KV_VALUE "$PARTITION" "$CHAIN_PARTITIONS")"
        if [ -n "$LOCATION" ]; then
            LOGW "Removing $PARTITION from TARGET_AVB_CHAIN_PARTITIONS; verification for this partition is disabled"
            REMOVE_KV_ITEM "CHAIN_PARTITIONS" "$PARTITION"
        fi
    done

    for ENTRY in $ORIGINAL_HASH_PARTITIONS; do
        if IS_EXCLUDED_AVB_PARTITION "$ENTRY"; then
            LOG "- Ignoring original vbmeta hash descriptor for $ENTRY; verification for this partition is disabled"
            continue
        fi
        SET_PARTITION_SIGN_KIND "$ENTRY" "hash"
    done

    for ENTRY in $ORIGINAL_HASHTREE_PARTITIONS; do
        if IS_EXCLUDED_AVB_PARTITION "$ENTRY"; then
            LOG "- Ignoring original vbmeta hashtree descriptor for $ENTRY; verification for this partition is disabled"
            continue
        fi
        SET_PARTITION_SIGN_KIND "$ENTRY" "hashtree"
    done

    for ENTRY in $ORIGINAL_CHAIN_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        if IS_EXCLUDED_AVB_PARTITION "$PARTITION"; then
            LOG "- Ignoring original vbmeta chain descriptor for $PARTITION; verification for this partition is disabled"
            continue
        fi
        APPEND_UNIQUE "CHAIN_PARTITIONS" "$ENTRY"
    done

    for ENTRY in $TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS; do
        PARTITION="${ENTRY%%=*}"
        if IS_EXCLUDED_AVB_PARTITION "$PARTITION"; then
            LOG "- Ignoring configured firmware descriptor for $PARTITION; verification for this partition is disabled"
            continue
        fi
        SET_PARTITION_SIGN_KIND "$PARTITION" "hash"
    done

    LOG_PARTITION_SET "Merged AVB hash partitions" "$HASH_PARTITIONS"
    LOG_PARTITION_SET "Merged AVB hashtree partitions" "$HASHTREE_PARTITIONS"
    LOG_PARTITION_SET "Merged AVB chain partitions" "$CHAIN_PARTITIONS"
    LOG_PARTITION_SET "Include vbmeta partition descriptors" "$TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS"
    LOG_PARTITION_SET "Configured firmware descriptor overrides" "$TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS"
}

IS_PRESENT_IN_ORIGINAL_VBMETA()
{
    local PARTITION="$1"

    # If the stock layout cannot be parsed, treat configured/fallback
    # partitions as eligible so packaging can still produce a complete vbmeta.
    if [ -z "$ORIGINAL_HASH_PARTITIONS$ORIGINAL_HASHTREE_PARTITIONS$ORIGINAL_CHAIN_PARTITIONS" ]; then
        return 0
    fi

    LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASH_PARTITIONS" && return 0
    LIST_HAS_ITEM "$PARTITION" "$ORIGINAL_HASHTREE_PARTITIONS" && return 0
    [ -n "$(GET_KV_VALUE "$PARTITION" "$ORIGINAL_CHAIN_PARTITIONS")" ]
}

IS_EXPLICITLY_CONFIGURED_VBMETA_PARTITION()
{
    local PARTITION="$1"
    local ENTRY

    LIST_HAS_ITEM "$PARTITION" "$TARGET_AVB_HASH_PARTITIONS" && return 0
    LIST_HAS_ITEM "$PARTITION" "$TARGET_AVB_HASHTREE_PARTITIONS" && return 0
    [ -n "$(GET_KV_VALUE "$PARTITION" "$TARGET_AVB_CHAIN_PARTITIONS")" ] && return 0

    for ENTRY in $TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS; do
        [ "${ENTRY%%=*}" = "$PARTITION" ] && return 0
    done

    return 1
}

SHOULD_INCLUDE_IN_TOPLEVEL_VBMETA()
{
    local PARTITION="$1"

    IS_EXPLICITLY_CONFIGURED_VBMETA_PARTITION "$PARTITION" && return 0
    IS_PRESENT_IN_ORIGINAL_VBMETA "$PARTITION"
}

ASSERT_REQUIRED_RE_SIGN_COVERAGE()
{
    local PARTITION

    $TARGET_AVB_LOW_SECURITY && return 0

    # Built boot-chain images must either be re-signed or deliberately excluded;
    # silently packaging unsigned replacements would break verified boot.
    for PARTITION in $REQUIRED_RE_SIGN_PARTITIONS; do
        [ -f "$TMP_IMG_DIR/$PARTITION.img" ] || continue

        if LIST_HAS_ITEM "$PARTITION" "$HASH_PARTITIONS" || \
                LIST_HAS_ITEM "$PARTITION" "$HASHTREE_PARTITIONS" || \
                [ -n "$(GET_CHAIN_LOCATION "$PARTITION")" ]; then
            continue
        fi

        LOGE "AVB-relevant image $PARTITION.img is present but not configured for custom AVB re-signing. Add it to TARGET_AVB_HASH_PARTITIONS, TARGET_AVB_HASHTREE_PARTITIONS or TARGET_AVB_CHAIN_PARTITIONS."
        exit 1
    done
}
