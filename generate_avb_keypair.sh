#!/usr/bin/env bash
#
# Extract the repo AOSP platform key into AVB PEM/public-key form by default.
# Optionally generate a new keypair instead and/or update a target config.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTPUT_DIR="$ROOT_DIR/security/avb"
DEFAULT_AVBTOOL="$ROOT_DIR/tools/bin/avbtool"
DEFAULT_OUT_AVBTOOL="$ROOT_DIR/out/tools/bin/avbtool"
DEFAULT_AOSP_PK8="$ROOT_DIR/security/aosp_platform.pk8"

NAME="aosp_platform_avb"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
AVBTOOL_PATH=""
AVBTOOL_PYTHON=""
FORCE=false
TARGET_NAME=""
TARGET_CONFIG=""
GENERATE_NEW_KEY=false
AOSP_PK8_PATH="$DEFAULT_AOSP_PK8"

AVBTOOL_CMD=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --name NAME            Base name for generated files. Default: $NAME
  --output-dir DIR       Output directory. Default: $DEFAULT_OUTPUT_DIR
  --openssl PATH         Path to openssl. Default: $OPENSSL_BIN
  --avbtool PATH         avbtool binary or script. Default: $DEFAULT_AVBTOOL
  --avbtool-python PATH  Interpreter used to launch avbtool when needed
  --aosp-pk8 PATH        PKCS#8 DER key used for AVB extraction. Default: $DEFAULT_AOSP_PK8
  --generate             Generate a new RSA-4096 AVB key instead of extracting the repo AOSP key
  --target NAME          Update target/<name>/config.sh with the generated key path
  --target-config PATH   Update the specified target config file
  --force                Overwrite existing output files
  -h, --help             Show this help

Generated files:
  <output-dir>/<name>_private.pem
  <output-dir>/<name>_public.bin
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

print_command() {
    local part

    printf '+'
    for part in "$@"; do
        printf ' %q' "$part"
    done
    printf '\n'
}

require_tool() {
    local tool_path="$1"
    local label="$2"

    if [[ "$tool_path" == */* ]]; then
        [ -e "$tool_path" ] || die "$label not found: $tool_path"
    else
        command -v "$tool_path" >/dev/null 2>&1 || die "$label not found in PATH: $tool_path"
    fi
}

require_executable_path() {
    local tool_path="$1"
    local label="$2"

    if [[ "$tool_path" == */* ]]; then
        [ -x "$tool_path" ] || die "$label is not executable: $tool_path"
    fi
}

escape_shell_value() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

set_or_append_assignment() {
    local file="$1"
    local key="$2"
    local value="$3"
    local escaped
    local tmp_file

    escaped="$(escape_shell_value "$value")"
    tmp_file="$(mktemp)"

    awk -v key="$key" -v value="$escaped" '
        BEGIN { replaced = 0 }
        $0 ~ ("^" key "=") {
            if (!replaced) {
                print key "=\"" value "\""
                replaced = 1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print key "=\"" value "\""
            }
        }
    ' "$file" > "$tmp_file"

    mv -f "$tmp_file" "$file"
}

prepare_avbtool_command() {
    if [ -z "$AVBTOOL_PATH" ]; then
        if [ -x "$DEFAULT_AVBTOOL" ]; then
            AVBTOOL_PATH="$DEFAULT_AVBTOOL"
        elif [ -x "$DEFAULT_OUT_AVBTOOL" ]; then
            AVBTOOL_PATH="$DEFAULT_OUT_AVBTOOL"
        elif command -v avbtool >/dev/null 2>&1; then
            AVBTOOL_PATH="$(command -v avbtool)"
        else
            die "unable to locate avbtool. Pass --avbtool PATH or build CreckerROM tools first"
        fi
    fi

    require_tool "$AVBTOOL_PATH" "avbtool"

    if [ -n "$AVBTOOL_PYTHON" ]; then
        require_tool "$AVBTOOL_PYTHON" "avbtool python"
        AVBTOOL_CMD=("$AVBTOOL_PYTHON" "$AVBTOOL_PATH")
    else
        require_executable_path "$AVBTOOL_PATH" "avbtool"
        AVBTOOL_CMD=("$AVBTOOL_PATH")
    fi

    if ! "${AVBTOOL_CMD[@]}" version >/dev/null 2>&1; then
        die "configured avbtool could not be executed"
    fi
}

resolve_target_config() {
    if [ -n "$TARGET_NAME" ] && [ -n "$TARGET_CONFIG" ]; then
        die "use either --target or --target-config, not both"
    fi

    if [ -n "$TARGET_NAME" ]; then
        TARGET_CONFIG="$ROOT_DIR/target/$TARGET_NAME/config.sh"
    fi

    [ -z "$TARGET_CONFIG" ] && return 0
    [ -f "$TARGET_CONFIG" ] || die "target config not found: $TARGET_CONFIG"
}

update_target_config() {
    [ -n "$TARGET_CONFIG" ] || return 0

    set_or_append_assignment "$TARGET_CONFIG" "TARGET_ENABLE_CUSTOM_AVB" "true"
    set_or_append_assignment "$TARGET_CONFIG" "TARGET_AVB_KEY_PATH" "$PRIVATE_KEY_PATH"
    if $GENERATE_NEW_KEY; then
        set_or_append_assignment "$TARGET_CONFIG" "TARGET_AVB_ALGORITHM" "SHA256_RSA4096"
    else
        set_or_append_assignment "$TARGET_CONFIG" "TARGET_AVB_ALGORITHM" "SHA256_RSA2048"
    fi
    set_or_append_assignment "$TARGET_CONFIG" "TARGET_AVBTOOL_PATH" "$AVBTOOL_PATH"
    if [ -n "$AVBTOOL_PYTHON" ]; then
        set_or_append_assignment "$TARGET_CONFIG" "TARGET_AVBTOOL_PYTHON" "$AVBTOOL_PYTHON"
    else
        set_or_append_assignment "$TARGET_CONFIG" "TARGET_AVBTOOL_PYTHON" "none"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            shift
            NAME="${1:-}"
            ;;
        --output-dir)
            shift
            OUTPUT_DIR="${1:-}"
            ;;
        --openssl)
            shift
            OPENSSL_BIN="${1:-}"
            ;;
        --avbtool)
            shift
            AVBTOOL_PATH="${1:-}"
            ;;
        --avbtool-python)
            shift
            AVBTOOL_PYTHON="${1:-}"
            ;;
        --aosp-pk8)
            shift
            AOSP_PK8_PATH="${1:-}"
            ;;
        --generate)
            GENERATE_NEW_KEY=true
            ;;
        --target)
            shift
            TARGET_NAME="${1:-}"
            ;;
        --target-config)
            shift
            TARGET_CONFIG="${1:-}"
            ;;
        --force)
            FORCE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
    shift
done

[ -n "$NAME" ] || die "--name must not be empty"
[ -n "$OUTPUT_DIR" ] || die "--output-dir must not be empty"

resolve_target_config

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd || true)"
[ -n "$OUTPUT_DIR" ] || die "unable to resolve output directory"

PRIVATE_KEY_PATH="$OUTPUT_DIR/${NAME}_private.pem"
PUBLIC_KEY_PATH="$OUTPUT_DIR/${NAME}_public.bin"

require_tool "$OPENSSL_BIN" "openssl"
prepare_avbtool_command

if ! $GENERATE_NEW_KEY; then
    [ -f "$AOSP_PK8_PATH" ] || die "AOSP pk8 key not found: $AOSP_PK8_PATH"
fi

if ! $FORCE; then
    [ ! -e "$PRIVATE_KEY_PATH" ] || die "private key already exists: $PRIVATE_KEY_PATH"
    [ ! -e "$PUBLIC_KEY_PATH" ] || die "public key blob already exists: $PUBLIC_KEY_PATH"
fi

if $GENERATE_NEW_KEY; then
    print_command "$OPENSSL_BIN" genrsa -out "$PRIVATE_KEY_PATH" 4096
    "$OPENSSL_BIN" genrsa -out "$PRIVATE_KEY_PATH" 4096
else
    print_command "$OPENSSL_BIN" pkcs8 -inform DER -nocrypt -in "$AOSP_PK8_PATH" -out "$PRIVATE_KEY_PATH"
    "$OPENSSL_BIN" pkcs8 -inform DER -nocrypt -in "$AOSP_PK8_PATH" -out "$PRIVATE_KEY_PATH"
fi
chmod 600 "$PRIVATE_KEY_PATH"

print_command "${AVBTOOL_CMD[@]}" extract_public_key --key "$PRIVATE_KEY_PATH" --output "$PUBLIC_KEY_PATH"
"${AVBTOOL_CMD[@]}" extract_public_key --key "$PRIVATE_KEY_PATH" --output "$PUBLIC_KEY_PATH"

update_target_config

echo
echo "Generated:"
echo "  Private key : $PRIVATE_KEY_PATH"
echo "  Public blob : $PUBLIC_KEY_PATH"
echo "  avbtool     : $AVBTOOL_PATH"
if ! $GENERATE_NEW_KEY; then
    echo "  Source pk8  : $AOSP_PK8_PATH"
fi
if [ -n "$TARGET_CONFIG" ]; then
    echo "  Target cfg  : $TARGET_CONFIG (updated)"
fi

echo
echo "CreckerROM config:"
echo "  TARGET_ENABLE_CUSTOM_AVB=\"true\""
echo "  TARGET_AVB_KEY_PATH=\"$PRIVATE_KEY_PATH\""
if $GENERATE_NEW_KEY; then
    echo "  TARGET_AVB_ALGORITHM=\"SHA256_RSA4096\""
else
    echo "  TARGET_AVB_ALGORITHM=\"SHA256_RSA2048\""
fi
echo "  TARGET_AVBTOOL_PATH=\"$AVBTOOL_PATH\""
if [ -n "$AVBTOOL_PYTHON" ]; then
    echo "  TARGET_AVBTOOL_PYTHON=\"$AVBTOOL_PYTHON\""
else
    echo "  TARGET_AVBTOOL_PYTHON=\"none\""
fi
