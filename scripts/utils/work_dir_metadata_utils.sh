ENSURE_WORK_DIR_METADATA()
{
    _CHECK_NON_EMPTY_PARAM "PARTITION" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "ENTRY" "$2" || return 1

    local PARTITION="$1"
    local ENTRY="$2"
    local LOOKUP_PARTITION="$PARTITION"
    local LOOKUP_ENTRY="$ENTRY"
    local USER=""
    local GROUP=""
    local MODE=""
    local LABEL=""
    local HAVE_FS=false
    local HAVE_FC=false

    if ! IS_VALID_PARTITION_NAME "$PARTITION"; then
        LOGE "\"$PARTITION\" is not a valid partition name"
        return 1
    fi

    while [[ "${LOOKUP_ENTRY:0:1}" == "/" ]]; do
        LOOKUP_ENTRY="${LOOKUP_ENTRY:1}"
    done

    if ! $TARGET_HAS_SYSTEM_EXT && [[ "$LOOKUP_PARTITION" == "system_ext" ]]; then
        LOOKUP_PARTITION="system"
        LOOKUP_ENTRY="system/system_ext/$LOOKUP_ENTRY"
    elif [ "$LOOKUP_PARTITION" != "system" ] && [[ "$LOOKUP_ENTRY" != "$LOOKUP_PARTITION/"* ]]; then
        LOOKUP_ENTRY="$LOOKUP_PARTITION/$LOOKUP_ENTRY"
    fi

    local FS_CONFIG_FILE="$WORK_DIR/configs/fs_config-$LOOKUP_PARTITION"
    local FILE_CONTEXT_FILE="$WORK_DIR/configs/file_context-$LOOKUP_PARTITION"
    if [ ! -f "$FS_CONFIG_FILE" ] || [ ! -f "$FILE_CONTEXT_FILE" ]; then
        LOGW "Metadata files not found for partition \"$LOOKUP_PARTITION\""
        return 0
    fi

    if read -r USER GROUP MODE < <(grep -m1 -F "$LOOKUP_ENTRY " "$FS_CONFIG_FILE" 2> /dev/null | awk '{print $2, $3, $4}'); then
        [ -n "$USER" ] && [ -n "$GROUP" ] && [ -n "$MODE" ] && HAVE_FS=true
    fi

    local FC_ENTRY="/$(_HANDLE_SPECIAL_CHARS "$LOOKUP_ENTRY")"
    if read -r LABEL < <(grep -m1 -F "$FC_ENTRY " "$FILE_CONTEXT_FILE" 2> /dev/null | awk '{print $2}'); then
        [ -n "$LABEL" ] && HAVE_FC=true
    fi

    $HAVE_FS && $HAVE_FC && return 0

    local FILE_REL="$LOOKUP_ENTRY"
    if [ "$LOOKUP_PARTITION" != "system" ]; then
        FILE_REL="${LOOKUP_ENTRY#"$LOOKUP_PARTITION"/}"
    fi

    local FILE_PATH="$WORK_DIR"
    case "$LOOKUP_PARTITION" in
        "system_ext")
            if $TARGET_HAS_SYSTEM_EXT; then
                FILE_PATH+="/system_ext/$FILE_REL"
            else
                FILE_PATH+="/system/system/system_ext/$FILE_REL"
            fi
            ;;
        *)
            FILE_PATH+="/$LOOKUP_PARTITION/$FILE_REL"
            ;;
    esac

    if [ ! -e "$FILE_PATH" ] && [ ! -L "$FILE_PATH" ]; then
        LOGW "File not found while restoring metadata: ${FILE_PATH//$WORK_DIR/}"
        return 0
    fi

    if ! $HAVE_FS; then
        USER=0
        GROUP=0
        MODE=644
        if [ -d "$FILE_PATH" ]; then
            [[ "$LOOKUP_PARTITION" == "vendor" ]] && GROUP=2000
            MODE=755
        fi
    fi

    if ! $HAVE_FC; then
        local SELINUX_CONTEXTS_FILE=""
        case "$LOOKUP_PARTITION" in
            "product")
                SELINUX_CONTEXTS_FILE="$WORK_DIR/product/etc/selinux/product_file_contexts"
                ;;
            "vendor")
                SELINUX_CONTEXTS_FILE="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
                ;;
            "system_ext")
                if $TARGET_HAS_SYSTEM_EXT; then
                    SELINUX_CONTEXTS_FILE="$WORK_DIR/system_ext/etc/selinux/system_ext_file_contexts"
                else
                    SELINUX_CONTEXTS_FILE="$WORK_DIR/system/system/system_ext/etc/selinux/system_ext_file_contexts"
                fi
                ;;
            *)
                SELINUX_CONTEXTS_FILE="$WORK_DIR/system/system/etc/selinux/plat_file_contexts"
                ;;
        esac

        if [ -f "$SELINUX_CONTEXTS_FILE" ]; then
            LABEL="$(_GET_SELINUX_LABEL "$LOOKUP_PARTITION" "/$LOOKUP_ENTRY")"
        fi
        if [ -z "$LABEL" ]; then
            case "$LOOKUP_PARTITION" in
                "vendor" | "vendor_dlkm" | "odm" | "odm_dlkm")
                    LABEL="u:object_r:vendor_file:s0"
                    ;;
                *)
                    LABEL="u:object_r:system_file:s0"
                    ;;
            esac
        fi
    fi

    LOG "- Restoring metadata for /$LOOKUP_ENTRY (uid:$USER gid:$GROUP mode:$MODE selabel:$LABEL)"
    SET_METADATA "$LOOKUP_PARTITION" "$LOOKUP_ENTRY" "$USER" "$GROUP" "$MODE" "$LABEL"

    return 0
}

# EVAL <cmd>
# Executes the provided command and prints its output if it returns a non-zero exit code.
