
GET_SHARED_PRIVATE_SIGNING_KEY_PATH()
{
    local KEY_PATH="${TARGET_PLATFORM_KEY_SOURCE_PEM:-}"

    if [ "${TARGET_ENABLE_CUSTOM_AVB:-false}" = "true" ] && [ -n "${TARGET_AVB_KEY_PATH:-}" ] && [ "${TARGET_AVB_KEY_PATH:-none}" != "none" ]; then
        KEY_PATH="$TARGET_AVB_KEY_PATH"
    elif [ ! "$KEY_PATH" ]; then
        KEY_PATH="${TARGET_AVB_KEY_PATH:-$SRC_DIR/security/avb/creckerrom_avb_private.pem}"
    fi

    case "$KEY_PATH" in
        "" | "none" | "auto_aosp_platform" | */aosp_platform_avb.pem)
            KEY_PATH="$SRC_DIR/security/avb/creckerrom_avb_private.pem"
            ;;
    esac

    echo "$KEY_PATH"
}

GET_PLATFORM_CERT_X509_PATH()
{
    echo "${TARGET_PLATFORM_CERT_X509_PATH:-$SRC_DIR/security/creckerrom_platform.x509.pem}"
}

GET_PLATFORM_CERT_PK8_PATH()
{
    echo "${TARGET_PLATFORM_CERT_PK8_PATH:-$SRC_DIR/security/creckerrom_platform.pk8}"
}

GET_PLATFORM_CERT_SUBJECT()
{
    echo "${TARGET_PLATFORM_CERT_SUBJECT:-/CN=CreckerROM Platform/}"
}

_GET_PUBLIC_KEY_FROM_PRIVATE_PEM()
{
    _CHECK_NON_EMPTY_PARAM "FILE" "$1" || return 1
    openssl pkey -in "$1" -pubout 2> /dev/null
}

_GET_PUBLIC_KEY_FROM_X509()
{
    _CHECK_NON_EMPTY_PARAM "FILE" "$1" || return 1
    openssl x509 -in "$1" -pubkey -noout 2> /dev/null
}

_GET_PUBLIC_KEY_FROM_PK8()
{
    _CHECK_NON_EMPTY_PARAM "FILE" "$1" || return 1
    openssl pkcs8 -inform DER -in "$1" -nocrypt 2> /dev/null | openssl pkey -pubout 2> /dev/null
}

ENSURE_SHARED_PLATFORM_SIGNING_CERTS()
{
    local SOURCE_KEY_PATH
    local X509_PATH
    local PK8_PATH
    local CERT_SUBJECT
    local SOURCE_PUBKEY
    local X509_PUBKEY=""
    local PK8_PUBKEY=""

    SOURCE_KEY_PATH="$(GET_SHARED_PRIVATE_SIGNING_KEY_PATH)"
    X509_PATH="$(GET_PLATFORM_CERT_X509_PATH)"
    PK8_PATH="$(GET_PLATFORM_CERT_PK8_PATH)"
    CERT_SUBJECT="$(GET_PLATFORM_CERT_SUBJECT)"

    mkdir -p "$(dirname "$SOURCE_KEY_PATH")" "$(dirname "$X509_PATH")" "$(dirname "$PK8_PATH")"

    if [ ! -s "$SOURCE_KEY_PATH" ]; then
        LOG "- Generating shared custom signing key: ${SOURCE_KEY_PATH//$SRC_DIR\//}"
        openssl genpkey -algorithm RSA \
            -pkeyopt rsa_keygen_bits:4096 -out "$SOURCE_KEY_PATH" || return 1
        chmod 600 "$SOURCE_KEY_PATH" || return 1
    fi

    SOURCE_PUBKEY="$(_GET_PUBLIC_KEY_FROM_PRIVATE_PEM "$SOURCE_KEY_PATH")"
    if [ ! "$SOURCE_PUBKEY" ]; then
        LOGE "Unable to read shared signing key: ${SOURCE_KEY_PATH//$SRC_DIR\//}"
        return 1
    fi

    [ -s "$X509_PATH" ] && X509_PUBKEY="$(_GET_PUBLIC_KEY_FROM_X509 "$X509_PATH")"
    if [ ! -s "$X509_PATH" ] || [ "$X509_PUBKEY" != "$SOURCE_PUBKEY" ]; then
        [ -s "$X509_PATH" ] && LOGW "Regenerating platform certificate to match ${SOURCE_KEY_PATH//$SRC_DIR\//}"
        LOG "- Ensuring platform certificate: ${X509_PATH//$SRC_DIR\//}"
        openssl req -new -x509 -sha256 -key "$SOURCE_KEY_PATH" -out "$X509_PATH" -days 36500 -subj "$CERT_SUBJECT" || return 1
        chmod 644 "$X509_PATH" || return 1
    fi

    [ -s "$PK8_PATH" ] && PK8_PUBKEY="$(_GET_PUBLIC_KEY_FROM_PK8 "$PK8_PATH")"
    if [ ! -s "$PK8_PATH" ] || [ "$PK8_PUBKEY" != "$SOURCE_PUBKEY" ]; then
        [ -s "$PK8_PATH" ] && LOGW "Regenerating platform pk8 to match ${SOURCE_KEY_PATH//$SRC_DIR\//}"
        LOG "- Ensuring platform pk8: ${PK8_PATH//$SRC_DIR\//}"
        openssl pkcs8 -in "$SOURCE_KEY_PATH" -topk8 -nocrypt -outform DER -out "$PK8_PATH" || return 1
        chmod 600 "$PK8_PATH" || return 1
    fi
}

GET_PLATFORM_CERT_SIGNATURE_HEX()
{
    local X509_PATH

    ENSURE_SHARED_PLATFORM_SIGNING_CERTS || return 1
    X509_PATH="$(GET_PLATFORM_CERT_X509_PATH)"

    sed '/CERTIFICATE/d' "$X509_PATH" | tr -d '\n' | base64 -d | xxd -p -c 0
}

GET_SHARED_PUBLIC_KEY_SHA256()
{
    local SOURCE_KEY_PATH
    SOURCE_KEY_PATH="$(GET_SHARED_PRIVATE_SIGNING_KEY_PATH)"

    openssl pkey -in "$SOURCE_KEY_PATH" -pubout -outform DER 2> /dev/null | openssl dgst -sha256 -r 2> /dev/null | cut -d " " -f 1
}

PRINT_SHARED_SIGNING_KEY_INFO()
{
    local SOURCE_KEY_PATH
    local X509_PATH
    local PK8_PATH
    local PUBLIC_KEY_SHA256
    local PUBLIC_KEY_PEM
    local MESSAGE

    ENSURE_SHARED_PLATFORM_SIGNING_CERTS || return 1

    SOURCE_KEY_PATH="$(GET_SHARED_PRIVATE_SIGNING_KEY_PATH)"
    X509_PATH="$(GET_PLATFORM_CERT_X509_PATH)"
    PK8_PATH="$(GET_PLATFORM_CERT_PK8_PATH)"
    PUBLIC_KEY_SHA256="$(GET_SHARED_PUBLIC_KEY_SHA256)"
    PUBLIC_KEY_PEM="$(_GET_PUBLIC_KEY_FROM_PRIVATE_PEM "$SOURCE_KEY_PATH")"

    MESSAGE="- Shared signing key ready: ${SOURCE_KEY_PATH//$SRC_DIR\//}"
    if [ "${TARGET_ENABLE_CUSTOM_AVB:-false}" = "true" ]; then
        MESSAGE+=" (used for AVB and rebuilt APK signing)"
    else
        MESSAGE+=" (used for rebuilt APK signing)"
    fi
    LOG "$MESSAGE"
    LOG "- Platform cert: ${X509_PATH//$SRC_DIR\//}"
    LOG "- Platform pk8: ${PK8_PATH//$SRC_DIR\//}"
    [ -n "$PUBLIC_KEY_SHA256" ] && LOG "- Shared public key sha256: $PUBLIC_KEY_SHA256"
    LOG "- Shared public key (PEM):"
    while IFS= read -r LINE; do
        LOG "  $LINE"
    done <<< "$PUBLIC_KEY_PEM"
}
