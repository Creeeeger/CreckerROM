GET_PACKAGE_MODEL_IDENTIFIER()
{
    local MODEL="${TARGET_SAMSUNG_BL1_MODEL:-}"

    if [ -z "$MODEL" ] || [ "$MODEL" = "none" ]; then
        MODEL="$TARGET_FIRMWARE_MODEL"
    fi
    case "$MODEL" in
        SM-*)
            ;;
        *)
            MODEL="SM-$MODEL"
            ;;
    esac

    if [[ ! "$MODEL" =~ ^SM-[A-Za-z0-9]+$ ]]; then
        LOGE "Unable to determine a valid package model identifier: $MODEL"
        return 1
    fi

    printf "%s\n" "$MODEL"
}

GET_ODIN_PACKAGE_DIR()
{
    printf "%s/%s\n" "$OUT_DIR" "$1"
}

GET_HEIMDALL_PACKAGE_DIR()
{
    printf "%s/%s_%s-heimdall\n" "$OUT_DIR" "$1" "$2"
}
