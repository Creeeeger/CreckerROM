FIND_PACKAGE_TAR()
{
    local DIRECTORY="$1"
    local PREFIX="$2"
    local RESULT=""

    RESULT="$(find "$DIRECTORY" -maxdepth 1 -type f \
        \( -name "${PREFIX}_*.tar.md5" -o -name "${PREFIX}_*.tar" -o -name "${PREFIX}_*.md5" \) \
        | sort -r | head -n 1)"
    [ -n "$RESULT" ] && echo "$RESULT"
}

EXTRACT_COMPONENT()
{
    local TAR_FILE="$1"
    local ENTRY="$2"
    local OUTPUT="$3"
    local REQUIRED="${4:-true}"
    local OUTPUT_DIR

    OUTPUT_DIR="$(dirname "$OUTPUT")"
    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT" "$OUTPUT.lz4" "$OUTPUT.ext4"

    if FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY"; then
        tar xf "$TAR_FILE" -O "$ENTRY" > "$OUTPUT"
    elif FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY.lz4"; then
        tar -xOf "$TAR_FILE" "$ENTRY.lz4" | lz4 -d - "$OUTPUT"
    elif FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY.ext4"; then
        tar xf "$TAR_FILE" -O "$ENTRY.ext4" > "$OUTPUT"
    elif $REQUIRED; then
        LOGE "$ENTRY was not found in $(basename "$TAR_FILE")"
        exit 1
    else
        return 1
    fi

    chmod u+w "$OUTPUT"
}

EXTRACT_PIT()
{
    local TAR_FILE="$1"
    local ENTRY

    ENTRY="$(tar tf "$TAR_FILE" | awk '/\.pit$/ { print; exit }')"
    [ -n "$ENTRY" ] || return 0
    tar xf "$TAR_FILE" -O "$ENTRY" > "$SOURCE_DIR/$(basename "$ENTRY")"
}

SET_PARTITION_SIZE()
{
    local PARTITION="$1"
    local IMAGE="$2"
    local SIZE
    local VAR_NAME

    # The shared AVB signer consumes TARGET_<PARTITION>_PARTITION_SIZE vars, so
    # export rollback sizes from extracted stock images.
    SIZE="$(GET_IMAGE_SIZE "$IMAGE")"
    VAR_NAME="TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE"
    printf -v "$VAR_NAME" '%s' "$SIZE"
    export "$VAR_NAME"
}

SET_PARTITION_SIZE_VALUE()
{
    local PARTITION="$1"
    local SIZE="$2"
    local VAR_NAME

    VAR_NAME="TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION" | tr '-' '_')_PARTITION_SIZE"
    printf -v "$VAR_NAME" '%s' "$SIZE"
    export "$VAR_NAME"
}
