SETUP_AVBTOOL()
{
    if [ ! -f "$UPSTREAM_AVBTOOL_PATH" ]; then
        LOGE "Official AVB reference not found: $UPSTREAM_AVBTOOL_PATH"
        exit 1
    fi

    if [ "$TARGET_AVBTOOL_PATH" != "none" ] && [ "$TARGET_AVBTOOL_PATH" != "$UPSTREAM_AVBTOOL_PATH" ]; then
        LOGW "Ignoring TARGET_AVBTOOL_PATH=$TARGET_AVBTOOL_PATH. Using official AVB reference: $UPSTREAM_AVBTOOL_PATH"
    fi

    TARGET_AVBTOOL_PATH="$UPSTREAM_AVBTOOL_PATH"
    AVBTOOL_PATH="$UPSTREAM_AVBTOOL_PATH"

    if [ "$TARGET_AVBTOOL_PYTHON" != "none" ]; then
        if [[ "$TARGET_AVBTOOL_PYTHON" == */* ]]; then
            [ -x "$TARGET_AVBTOOL_PYTHON" ] || {
                LOGE "Configured AVB python is not executable: $TARGET_AVBTOOL_PYTHON"
                exit 1
            }
        elif ! command -v "$TARGET_AVBTOOL_PYTHON" &> /dev/null; then
            LOGE "Configured AVB python not found in PATH: $TARGET_AVBTOOL_PYTHON"
            exit 1
        fi
        AVB_PYTHON_BIN="$TARGET_AVBTOOL_PYTHON"
    else
        if ! command -v python3 &> /dev/null; then
            LOGE "python3 is required to execute avbtool script: $AVBTOOL_PATH"
            exit 1
        fi
        AVB_PYTHON_BIN="$(command -v python3)"
        TARGET_AVBTOOL_PYTHON="$AVB_PYTHON_BIN"
    fi

    AVBTOOL_CMD=("$AVB_PYTHON_BIN" "$AVBTOOL_PATH")

    AVB_DEBUG_LOG "Using AVB python: $AVB_PYTHON_BIN"
    AVB_DEBUG_LOG "Using AVB tool: $AVBTOOL_PATH"

    if ! "${AVBTOOL_CMD[@]}" version &> /dev/null; then
        LOGE "Configured avbtool could not be executed. Check TARGET_AVBTOOL_PATH/TARGET_AVBTOOL_PYTHON"
        exit 1
    fi
}

GET_AVB_KEY_BITS()
{
    case "$1" in
        SHA256_RSA2048 | SHA512_RSA2048)
            echo "2048"
            ;;
        SHA256_RSA4096 | SHA512_RSA4096)
            echo "4096"
            ;;
        SHA256_RSA8192 | SHA512_RSA8192)
            echo "8192"
            ;;
        *)
            LOGE "Unsupported AVB signing algorithm for auto-generated key: $1"
            exit 1
            ;;
    esac
}

GET_AVB_PUBLIC_KEY_OUTPUT_PATH()
{
    local PRIVATE_KEY_PATH="$1"

    if [[ "$PRIVATE_KEY_PATH" == *_private.pem ]]; then
        echo "${PRIVATE_KEY_PATH%_private.pem}_public.bin"
    elif [[ "$PRIVATE_KEY_PATH" == *.pem ]]; then
        echo "${PRIVATE_KEY_PATH%.pem}_public.bin"
    else
        echo "${PRIVATE_KEY_PATH}.public.bin"
    fi
}

ENSURE_GENERATED_AVB_KEY()
{
    local KEY_PATH="$1"
    local ALGORITHM="$2"
    local KEY_BITS
    local PUBLIC_KEY_PATH

    [ -n "$KEY_PATH" ] && [ "$KEY_PATH" != "none" ] || {
        LOGE "Missing AVB key path for custom AVB flow"
        exit 1
    }
    [ "$ALGORITHM" != "NONE" ] || return 0

    if ! command -v openssl &> /dev/null; then
        LOGE "openssl is required to generate the custom AVB key"
        exit 1
    fi

    KEY_BITS="$(GET_AVB_KEY_BITS "$ALGORITHM")"
    mkdir -p "$(dirname "$KEY_PATH")"

    if [ ! -f "$KEY_PATH" ]; then
        LOG "- Generating custom AVB key ($ALGORITHM) at $KEY_PATH"
        openssl genpkey -algorithm RSA \
            -pkeyopt "rsa_keygen_bits:$KEY_BITS" -out "$KEY_PATH" || exit 1
        chmod 600 "$KEY_PATH"
    fi

    PUBLIC_KEY_PATH="$(GET_AVB_PUBLIC_KEY_OUTPUT_PATH "$KEY_PATH")"
    if [ ! -f "$PUBLIC_KEY_PATH" ] || [ "$KEY_PATH" -nt "$PUBLIC_KEY_PATH" ]; then
        LOG "- Extracting AVB public key blob to $PUBLIC_KEY_PATH"
        RUN_AVBTOOL extract_public_key --key "$KEY_PATH" --output "$PUBLIC_KEY_PATH" || exit 1
    fi
}

RESOLVE_AVB_KEY_PATH()
{
    local KEY_VALUE="$1"
    local ALGORITHM="$2"

    if [ -n "$KEY_VALUE" ] && [ "$KEY_VALUE" != "none" ]; then
        [ -f "$KEY_VALUE" ] || ENSURE_GENERATED_AVB_KEY "$KEY_VALUE" "$ALGORITHM" >&2
        echo "$KEY_VALUE"
    fi
}

RESOLVE_TOPLEVEL_SIGNING_CONFIG()
{
    local KEY_VALUE="$TARGET_AVB_KEY_PATH"

    VBMETA_SIGN_ALGORITHM="$TARGET_AVB_ALGORITHM"
    VBMETA_SIGN_KEY_PATH="$(RESOLVE_AVB_KEY_PATH "$KEY_VALUE" "$VBMETA_SIGN_ALGORITHM")"
    if [ "$VBMETA_SIGN_ALGORITHM" = "NONE" ]; then
        LOGE "Top-level vbmeta must be signed with a real AVB key"
        exit 1
    fi
    if [ -z "$VBMETA_SIGN_KEY_PATH" ]; then
        LOGE "Missing AVB key for top-level vbmeta (algorithm=$VBMETA_SIGN_ALGORITHM)"
        exit 1
    fi

    AVB_DEBUG_LOG "Top-level vbmeta signing config: algorithm=$VBMETA_SIGN_ALGORITHM key=$VBMETA_SIGN_KEY_PATH rollback_index=$TARGET_AVB_ROLLBACK_INDEX rollback_index_location=$TARGET_AVB_ROLLBACK_INDEX_LOCATION hash_algorithm=$TARGET_AVB_HASH_ALGORITHM"
}

SANITIZE_KEY_LABEL()
{
    printf '%s' "$1" | tr '/:[:space:]' '___' | tr -cd '[:alnum:]_.-'
}

CALCULATE_SHA256()
{
    if command -v shasum &> /dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        python3 - "$1" <<'PY'
import hashlib
import sys

with open(sys.argv[1], 'rb') as fp:
    print(hashlib.sha256(fp.read()).hexdigest())
PY
    fi
}

REGISTER_KEY_USAGE()
{
    local LABEL="$1"
    local KEY_PATH="$2"
    local ALGORITHM="$3"
    local SAFE_LABEL
    local OUTPUT_BLOB
    local DIGEST

    # Key export data is informational for flashing/custom-key setup; signing
    # itself continues to use the private key paths resolved above.
    [ -n "$KEY_PATH" ] || return 0

    SAFE_LABEL="$(SANITIZE_KEY_LABEL "$LABEL")"
    LIST_HAS_ITEM "$SAFE_LABEL" "$KEY_EXPORT_LABELS" && return 0

    mkdir -p "$STAGING_DIR/keys"
    OUTPUT_BLOB="$STAGING_DIR/keys/${SAFE_LABEL}.avbpubkey"
    RUN_AVBTOOL extract_public_key --key "$KEY_PATH" --output "$OUTPUT_BLOB" || exit 1
    DIGEST="$(CALCULATE_SHA256 "$OUTPUT_BLOB")"
    APPEND_UNIQUE "KEY_EXPORT_LABELS" "$SAFE_LABEL"

    {
        echo "label=$LABEL"
        echo "algorithm=$ALGORITHM"
        echo "private_key=$KEY_PATH"
        echo "public_key_blob=keys/${SAFE_LABEL}.avbpubkey"
        echo "public_key_sha256=$DIGEST"
        echo
    } >> "$KEY_EXPORT_REPORT"
}

REGISTER_PARTITION_KEY_USAGE_IF_NEEDED()
{
    local PARTITION="$1"
    local CHAIN_LOCATION=""

    [ -n "$PARTITION_SIGN_KEY_PATH" ] || return 0

    CHAIN_LOCATION="$(GET_CHAIN_LOCATION "$PARTITION")"
    if [ -n "$CHAIN_LOCATION" ] || \
            [ "$PARTITION_SIGN_KEY_PATH" != "$VBMETA_SIGN_KEY_PATH" ] || \
            [ "$PARTITION_SIGN_ALGORITHM" != "$VBMETA_SIGN_ALGORITHM" ]; then
        REGISTER_KEY_USAGE "$PARTITION" "$PARTITION_SIGN_KEY_PATH" "$PARTITION_SIGN_ALGORITHM"
    fi
}

ASSERT_IMAGE_VBMETA_FLAGS_ZERO()
{
    local IMAGE="$1"
    local LABEL="$2"
    local FLAGS=""

    # Custom signing must not depend on disable-verification or disable-hashtree
    # flags; those would make the generated signatures meaningless.
    FLAGS="$(
        "$AVB_PYTHON_BIN" "$AVB_METADATA_TOOL" \
            --avbtool "$AVBTOOL_PATH" flags --image "$IMAGE"
    )"

    if [ "$FLAGS" != "0" ]; then
        LOGE "$LABEL has insecure vbmeta flags set ($FLAGS). Verification/hashtree disabling is not allowed in the custom AVB flow."
        exit 1
    fi
}

RESOLVE_PARTITION_SIGNING_CONFIG()
{
    local PARTITION="$1"
    local KIND="$2"
    local KEY_VALUE=""
    local CHAIN_LOCATION=""

    PARTITION_SIGN_KEY_PATH=""
    PARTITION_SIGN_ALGORITHM="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ALGORITHM")"
    [ -z "$PARTITION_SIGN_ALGORITHM" ] && PARTITION_SIGN_ALGORITHM="$TARGET_AVB_ALGORITHM"

    PARTITION_SIGN_HASH_ALGORITHM="$(GET_PARTITION_VAR_VALUE "$PARTITION" "HASH_ALGORITHM")"
    [ -z "$PARTITION_SIGN_HASH_ALGORITHM" ] && PARTITION_SIGN_HASH_ALGORITHM="$TARGET_AVB_HASH_ALGORITHM"

    PARTITION_SIGN_ROLLBACK_INDEX="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ROLLBACK_INDEX")"
    [ -z "$PARTITION_SIGN_ROLLBACK_INDEX" ] && PARTITION_SIGN_ROLLBACK_INDEX="$TARGET_AVB_ROLLBACK_INDEX"

    PARTITION_SIGN_ROLLBACK_INDEX_LOCATION="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ROLLBACK_INDEX_LOCATION")"
    CHAIN_LOCATION="$(GET_CHAIN_LOCATION "$PARTITION")"
    # Keep chained partition footers at rollback_index_location=0 by default.
    # The chain descriptor in top-level vbmeta carries the real rollback slot.
    [ -z "$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION" ] && PARTITION_SIGN_ROLLBACK_INDEX_LOCATION="0"
    if [ -n "$CHAIN_LOCATION" ] && [ "$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION" != "0" ]; then
        AVB_DEBUG_LOG "Chained partition $PARTITION uses explicit footer rollback_index_location=$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION; this may raise required libavb version above stock."
    fi

    PARTITION_SIGN_DO_NOT_USE_AB="$(GET_PARTITION_VAR_VALUE "$PARTITION" "DO_NOT_USE_AB")"
    [ -z "$PARTITION_SIGN_DO_NOT_USE_AB" ] && PARTITION_SIGN_DO_NOT_USE_AB="false"

    if [ "$KIND" = "hashtree" ]; then
        PARTITION_SIGN_EXTRA_ARGS="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ADD_HASHTREE_FOOTER_ARGS")"
    else
        PARTITION_SIGN_EXTRA_ARGS="$(GET_PARTITION_VAR_VALUE "$PARTITION" "ADD_HASH_FOOTER_ARGS")"
    fi

    KEY_VALUE="$(GET_PARTITION_VAR_VALUE "$PARTITION" "KEY_PATH")"
    [ -z "$KEY_VALUE" ] && KEY_VALUE="$TARGET_AVB_KEY_PATH"
    PARTITION_SIGN_KEY_PATH="$(RESOLVE_AVB_KEY_PATH "$KEY_VALUE" "$PARTITION_SIGN_ALGORITHM")"

    if [ "$PARTITION_SIGN_ALGORITHM" = "NONE" ]; then
        LOGE "Partition $PARTITION must use a real AVB signing algorithm"
        exit 1
    fi

    if [ -z "$PARTITION_SIGN_KEY_PATH" ]; then
        LOGE "Missing AVB key for partition $PARTITION (algorithm=$PARTITION_SIGN_ALGORITHM)"
        exit 1
    fi

    AVB_DEBUG_LOG "Partition signing config for $PARTITION: kind=$KIND algorithm=$PARTITION_SIGN_ALGORITHM key=$PARTITION_SIGN_KEY_PATH hash_algorithm=$PARTITION_SIGN_HASH_ALGORITHM rollback_index=$PARTITION_SIGN_ROLLBACK_INDEX rollback_index_location=$PARTITION_SIGN_ROLLBACK_INDEX_LOCATION do_not_use_ab=$PARTITION_SIGN_DO_NOT_USE_AB extra_args=${PARTITION_SIGN_EXTRA_ARGS:-<none>}"

}

GET_CHAIN_PUBLIC_KEY_BLOB()
{
    local PARTITION="$1"
    local KEY_PATH="$2"
    local OUTPUT_PATH="$STAGING_DIR/${PARTITION}_public_key.bin"

    # Top-level vbmeta chain descriptors need a public-key blob file, not the
    # PEM private key used to sign the chained partition.
    [ -f "$OUTPUT_PATH" ] || RUN_AVBTOOL extract_public_key --key "$KEY_PATH" --output "$OUTPUT_PATH" || exit 1
    echo "$OUTPUT_PATH"
}

RUN_AVBTOOL()
{
    AVB_DEBUG_LOG "Running avbtool: $(FORMAT_COMMAND "${AVBTOOL_CMD[@]}" "$@")"
    PATH="$OPENSSL_COMPAT_DIR:$PATH" "${AVBTOOL_CMD[@]}" "$@"
}
