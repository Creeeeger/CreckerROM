#
# Copyright (C) 2025 Salvo Giangreco
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# [
source "$SRC_DIR/scripts/utils/log_utils.sh"

_CHECK_NON_EMPTY_PARAM()
{
    if [ ! "$2" ]; then
        echo -n -e '\033[0;31m' >&2

        local STACK_SIZE="${#FUNCNAME[@]}"
        if [[ "$STACK_SIZE" -gt "1" ]]; then
            echo -n "(" >&2
            if [[ "$STACK_SIZE" -gt "2" ]]; then
                echo -n "${BASH_SOURCE[2]//$SRC_DIR\//}:${BASH_LINENO[1]}:" >&2
            fi
            echo -n "${FUNCNAME[1]}) " >&2
        fi

        echo -n "$1 is not set!" >&2
        echo -e '\033[0m' >&2

        return 1
    fi

    return 0
}

_GET_PROP_FILES_PATH()
{
    local PARTITION="$1"
    local FILES=()

    if IS_VALID_PARTITION_NAME "$PARTITION"; then
        case "$PARTITION" in
            "system")
                FILES+=("$WORK_DIR/system/system/build.prop")
                ;;
            "vendor")
                FILES+=(
                    "$WORK_DIR/vendor/default.prop"
                    "$WORK_DIR/vendor/build.prop"
                )
                ;;
            "product")
                FILES+=("$WORK_DIR/product/etc/build.prop")
                ;;
            "system_ext")
                FILES+=(
                    "$WORK_DIR/system_ext/etc/build.prop"
                    "$WORK_DIR/system/system/system_ext/etc/build.prop"
                )
                ;;
            "odm")
                FILES+=("$WORK_DIR/odm/etc/build.prop")
                ;;
            "vendor_dlkm")
                FILES+=(
                    "$WORK_DIR/vendor_dlkm/etc/build.prop"
                    "$WORK_DIR/vendor/vendor_dlkm/etc/build.prop"
                )
                ;;
            "odm_dlkm")
                FILES+=("$WORK_DIR/vendor/odm_dlkm/etc/build.prop")
                ;;
            "system_dlkm")
                FILES+=(
                    "$WORK_DIR/system_dlkm/etc/build.prop"
                    "$WORK_DIR/system/system/system_dlkm/etc/build.prop"
                )
                ;;
        esac
    else
        # https://android.googlesource.com/platform/system/core/+/refs/tags/android-15.0.0_r1/init/property_service.cpp#1214
        FILES+=(
            "$WORK_DIR/system/system/build.prop"
            "$WORK_DIR/system_ext/etc/build.prop"
            "$WORK_DIR/system/system/system_ext/etc/build.prop"
            "$WORK_DIR/system_dlkm/etc/build.prop"
            "$WORK_DIR/system/system/system_dlkm/etc/build.prop"
            "$WORK_DIR/vendor/default.prop"
            "$WORK_DIR/vendor/build.prop"
            "$WORK_DIR/vendor_dlkm/etc/build.prop"
            "$WORK_DIR/vendor/vendor_dlkm/etc/build.prop"
            "$WORK_DIR/vendor/odm_dlkm/etc/build.prop"
            "$WORK_DIR/odm/etc/build.prop"
            "$WORK_DIR/product/etc/build.prop"
        )
    fi

    printf '%s\n' "${FILES[@]}"
}

_GET_SELINUX_LABEL()
{
    _CHECK_NON_EMPTY_PARAM "PARTITION" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "FILE" "$2" || return 1

    local PARTITION="$1"
    local FILE="$2"
    local FC_FILE

    case "$PARTITION" in
        "product")
            FC_FILE="$WORK_DIR/product/etc/selinux/product_file_contexts"
            ;;
        "vendor")
            FC_FILE="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
            ;;
        "system_ext")
            if $TARGET_HAS_SYSTEM_EXT; then
                FC_FILE="$WORK_DIR/system_ext/etc/selinux/system_ext_file_contexts"
            else
                FC_FILE="$WORK_DIR/system/system/system_ext/etc/selinux/system_ext_file_contexts"
            fi
            ;;
        *)
            FC_FILE="$WORK_DIR/system/system/etc/selinux/plat_file_contexts"
            ;;
    esac

    if [ ! -f "$FC_FILE" ]; then
        LOGE "File not found: ${FC_FILE//$WORK_DIR/}"
        return 1
    fi

    if [[ "${FILE:0:1}" != "/" ]]; then
        FILE="/$FILE"
    fi

    local LABEL
    LABEL=$(perl -ne '
        next if /^\s*#/ || /^\s*$/;
        s/\s+/ /g;
        my ($pattern, $label) = split(" ", $_, 3);
        if ($ARGV[0] =~ /^$pattern$/) {
            print "$label\n";
            exit;
        }
    ' - "$FILE" <<< "$(tac "$FC_FILE")")
    echo "$LABEL"
}

_HANDLE_SPECIAL_CHARS()
{
    local STRING="${1:?}"

    STRING="${STRING//\./\\.}"
    STRING="${STRING//\+/\\+}"
    STRING="${STRING//\[/\\[}"
    STRING="${STRING//\]/\\]}"
    STRING="${STRING//\*/\\*}"

    echo "$STRING"
}

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
        openssl genrsa -out "$SOURCE_KEY_PATH" 4096 || return 1
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
# ]

# ADD_TO_WORK_DIR <source> <partition> <file/dir> <user> <group> <mode> <label>
# Adds the supplied file/directory in work dir along with its entries in fs_config/file_context.
#
# `source` argument can be:
# - a full path
# - a string in the following format: "MODEL/CSC" (the folder MUST exist under `out/fw`)
# - a string with the product name of the desidered device's prebuilt blobs (the folder MUST exist under `prebuilts/samsung`)
#
# `user`/`group`/`mode`/`label`/ arguments can be omitted as long as the respective entry is present in `source`/fs_config and `source`/file_context.
ADD_TO_WORK_DIR()
{
    _CHECK_NON_EMPTY_PARAM "SOURCE" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "PARTITION" "$2" || return 1
    _CHECK_NON_EMPTY_PARAM "FILE" "$3" || return 1

    local SOURCE="$1"
    local PARTITION="$2"
    local FILE="$3"
    local USER="$4"
    local GROUP="$5"
    local MODE="$6"
    local LABEL="$7"

    if [ ! -d "$SOURCE" ]; then
        if [ "$(cut -d "/" -f 2 -s <<< "$SOURCE")" ]; then
            SOURCE="$FW_DIR/$(cut -d "/" -f 1 <<< "$SOURCE")_$(cut -d "/" -f 2 <<< "$SOURCE")"
        else
            SOURCE="$SRC_DIR/prebuilts/samsung/$SOURCE"
        fi
    fi

    if [ ! -d "$SOURCE" ]; then
        LOGE "Folder not found: ${SOURCE//$SRC_DIR\//}"
        return 1
    fi

    if ! IS_VALID_PARTITION_NAME "$PARTITION"; then
        LOGE "\"$PARTITION\" is not a valid partition name"
        return 1
    fi

    while [[ "${FILE:0:1}" == "/" ]]; do
        FILE="${FILE:1}"
    done

    local SOURCE_FILE="$SOURCE"
    local TARGET_FILE="$WORK_DIR"
    if [[ "$PARTITION" == "system_ext" ]]; then
        if [ -d "$SOURCE/system_ext" ]; then
            SOURCE_FILE+="/system_ext/$FILE"
        elif [ -d "$SOURCE/system/system/system_ext" ]; then
            SOURCE_FILE+="/system/system/system_ext/$FILE"
        else
            SOURCE_FILE+="/system/system_ext/$FILE"
        fi

        if $TARGET_HAS_SYSTEM_EXT; then
            TARGET_FILE+="/system_ext/$FILE"
        else
            PARTITION="system"
            FILE="system/system_ext/$FILE"
            TARGET_FILE+="/system/$FILE"
        fi
    elif [[ "$PARTITION" == "system" ]]; then
        if [ -d "$SOURCE/system/system" ]; then
            SOURCE_FILE+="/system/$FILE"
            TARGET_FILE+="/system/$FILE"
        else
            SOURCE_FILE+="/system/${FILE//system\//}"
            TARGET_FILE+="/system/system/${FILE//system\//}"
        fi
    else
        SOURCE_FILE+="/$PARTITION/$FILE"
        TARGET_FILE+="/$PARTITION/$FILE"
    fi

    if [ ! -e "$SOURCE_FILE" ] && [ ! -L "$SOURCE_FILE" ]; then
        if [ -e "$SOURCE_FILE.00" ]; then
            LOG "- Adding $(sed -e "s|$WORK_DIR||" -e "s|/\.||" <<< "$TARGET_FILE") from ${SOURCE//$SRC_DIR\//}"
            mkdir -p "$(dirname "$TARGET_FILE")"
            EVAL "cat \"$SOURCE_FILE.\"* > \"$TARGET_FILE\"" || exit 1
        else
            LOGE "File not found: ${SOURCE_FILE//$SRC_DIR\//}"
            return 1
        fi
    else
        LOG "- Adding $(sed -e "s|$WORK_DIR||" -e "s|/\.||" <<< "$TARGET_FILE") from ${SOURCE//$SRC_DIR\//}"
        if [ ! -d "$SOURCE_FILE" ]; then
            mkdir -p "$(dirname "$TARGET_FILE")"
        else
            mkdir -p "$TARGET_FILE"
        fi
        EVAL "cp -a -T \"$SOURCE_FILE\" \"$TARGET_FILE\"" || exit 1
    fi

    local ENTRY="${TARGET_FILE//$WORK_DIR\//}"
    [[ "$PARTITION" == "system" ]] && ENTRY="${ENTRY//system\/system\//system/}"
    ENTRY="${ENTRY%/.}"

    if ! grep -q -F "$ENTRY " "$WORK_DIR/configs/fs_config-$PARTITION" 2> /dev/null; then
        if [ "$USER" ] && [ "$GROUP" ] && [ "$MODE" ]; then
            echo "$ENTRY $USER $GROUP $MODE capabilities=0x0" >> "$WORK_DIR/configs/fs_config-$PARTITION"
        elif grep -q -F "$ENTRY " "$SOURCE/fs_config-$PARTITION" 2> /dev/null; then
            grep -F "$ENTRY " "$SOURCE/fs_config-$PARTITION" >> "$WORK_DIR/configs/fs_config-$PARTITION"
        else
            LOGW "No fs_config entry found for \"$ENTRY\" in \"${SOURCE//$SRC_DIR\//}\". Using default values"

            USER=0
            GROUP=0
            MODE=644
            if [ -d "$TARGET_FILE" ]; then
                [[ "$PARTITION" == "vendor" ]] && GROUP=2000
                MODE=755
            fi

            echo "$ENTRY $USER $GROUP $MODE capabilities=0x0" >> "$WORK_DIR/configs/fs_config-$PARTITION"
        fi
    fi

    if ! grep -q -F "/$(_HANDLE_SPECIAL_CHARS "$ENTRY") " "$WORK_DIR/configs/file_context-$PARTITION" 2> /dev/null; then
        if [ "$LABEL" ]; then
            echo "/$(_HANDLE_SPECIAL_CHARS "$ENTRY") $LABEL" >> "$WORK_DIR/configs/file_context-$PARTITION"
        elif grep -q -F "/$(_HANDLE_SPECIAL_CHARS "$ENTRY") " "$SOURCE/file_context-$PARTITION" 2> /dev/null; then
            grep -F "/$(_HANDLE_SPECIAL_CHARS "$ENTRY") " "$SOURCE/file_context-$PARTITION" >> "$WORK_DIR/configs/file_context-$PARTITION"
        else
            LOGW "No file_context entry found for \"$ENTRY\" in \"${SOURCE//$SRC_DIR\//}\". Using default value"

            LABEL="$(_GET_SELINUX_LABEL "$PARTITION" "/$ENTRY")"

            echo "/$(_HANDLE_SPECIAL_CHARS "$ENTRY") $LABEL" >> "$WORK_DIR/configs/file_context-$PARTITION"
        fi
    fi

    if [ -d "$TARGET_FILE" ]; then
        local FILES
        FILES="$(find "${SOURCE_FILE%/.}")"
        FILES="${FILES//$SOURCE\//}"
        [[ "$PARTITION" == "system" ]] && FILES="${FILES//system\/system\//system/}"
        $TARGET_HAS_SYSTEM_EXT || FILES="${FILES//system_ext\//system/system_ext/}"

        while IFS= read -r f; do
            IS_VALID_PARTITION_NAME "$f" && continue

            if ! grep -q -F "$f " "$WORK_DIR/configs/fs_config-$PARTITION" 2> /dev/null; then
                if grep -q -F "$f " "$SOURCE/fs_config-$PARTITION" 2> /dev/null; then
                    grep -F "$f " "$SOURCE/fs_config-$PARTITION" >> "$WORK_DIR/configs/fs_config-$PARTITION"
                else
                    LOGW "No fs_config entry found for \"$f\" in \"${SOURCE//$SRC_DIR\//}\". Using default values"

                    USER=0
                    GROUP=0
                    MODE=644
                    if [ -d "$SOURCE/$f" ] || [ -d "$SOURCE/system/$f" ] || [ -d "$SOURCE/${f//system\//}" ]; then
                        [[ "$PARTITION" == "vendor" ]] && GROUP=2000
                        MODE=755
                    fi

                    echo "$f $USER $GROUP $MODE capabilities=0x0" >> "$WORK_DIR/configs/fs_config-$PARTITION"
                fi
            fi

            if ! grep -q -F "/$(_HANDLE_SPECIAL_CHARS "$f") " "$WORK_DIR/configs/file_context-$PARTITION" 2> /dev/null; then
                if grep -q -F "/$(_HANDLE_SPECIAL_CHARS "$f") " "$SOURCE/file_context-$PARTITION" 2> /dev/null; then
                    grep -F "/$(_HANDLE_SPECIAL_CHARS "$f") " "$SOURCE/file_context-$PARTITION" >> "$WORK_DIR/configs/file_context-$PARTITION"
                else
                    LOGW "No file_context entry found for \"$f\" in \"${SOURCE//$SRC_DIR\//}\". Using default value"

                    LABEL="$(_GET_SELINUX_LABEL "$PARTITION" "/$f")"

                    echo "/$(_HANDLE_SPECIAL_CHARS "$f") $LABEL" >> "$WORK_DIR/configs/file_context-$PARTITION"
                fi
            fi
        done <<< "$FILES"
    else
        local TMP="${TARGET_FILE%/.}"
        TMP="$(dirname "${TMP//$WORK_DIR\//}")"
        [[ "$PARTITION" == "system" ]] && TMP="${TMP//system\/system\//system/}"

        while [[ "$TMP" != "." ]]; do
            IS_VALID_PARTITION_NAME "$TMP" && break

            if ! grep -q -F "$TMP " "$WORK_DIR/configs/fs_config-$PARTITION" 2> /dev/null; then
                if grep -q -F "$TMP " "$SOURCE/fs_config-$PARTITION" 2> /dev/null; then
                    grep -F "$TMP " "$SOURCE/fs_config-$PARTITION" >> "$WORK_DIR/configs/fs_config-$PARTITION"
                else
                    LOGW "No fs_config entry found for \"$TMP\" in \"${SOURCE//$SRC_DIR\//}\". Using default values"

                    USER=0
                    GROUP=0
                    MODE=755
                    [[ "$PARTITION" == "vendor" ]] && GROUP=2000

                    echo "$TMP $USER $GROUP $MODE capabilities=0x0" >> "$WORK_DIR/configs/fs_config-$PARTITION"
                fi
            fi

            if ! grep -q -F "/$(_HANDLE_SPECIAL_CHARS "$TMP") " "$WORK_DIR/configs/file_context-$PARTITION" 2> /dev/null; then
                if grep -q -F "/$(_HANDLE_SPECIAL_CHARS "$TMP") " "$SOURCE/file_context-$PARTITION" 2> /dev/null; then
                    grep -F "/$(_HANDLE_SPECIAL_CHARS "$TMP") " "$SOURCE/file_context-$PARTITION" >> "$WORK_DIR/configs/file_context-$PARTITION"
                else
                    LOGW "No file_context entry found for \"$TMP\" in \"${SOURCE//$SRC_DIR\//}\". Using default value"

                    LABEL="$(_GET_SELINUX_LABEL "$PARTITION" "/$TMP")"

                    echo "/$(_HANDLE_SPECIAL_CHARS "$TMP") $LABEL" >> "$WORK_DIR/configs/file_context-$PARTITION"
                fi
            fi

            TMP="$(dirname "$TMP")"
        done
    fi

    return 0
}

# DELETE_FROM_WORK_DIR "<partition>" "<file/dir>"
# Deletes the supplied file/directory from work dir along with its entries in fs_config/file_context.
DELETE_FROM_WORK_DIR()
{
    _CHECK_NON_EMPTY_PARAM "PARTITION" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "FILE" "$2" || return 1

    local PARTITION="$1"
    local FILE="$2"

    if ! IS_VALID_PARTITION_NAME "$PARTITION"; then
        LOGE "\"$PARTITION\" is not a valid partition name"
        return 1
    fi

    while [[ "${FILE:0:1}" == "/" ]]; do
        FILE="${FILE:1}"
    done

    if ! $TARGET_HAS_SYSTEM_EXT && [[ "$PARTITION" == "system_ext" ]]; then
        PARTITION="system"
        FILE="system/system_ext/$FILE"
    fi

    local FILE_PATH="$WORK_DIR"
    case "$PARTITION" in
        "system_ext")
            if $TARGET_HAS_SYSTEM_EXT; then
                FILE_PATH+="/system_ext"
            else
                FILE_PATH+="/system/system/system_ext"
            fi
            ;;
        *)
            FILE_PATH+="/$PARTITION"
            ;;
    esac
    FILE_PATH+="/$FILE"

    if [ ! -e "$FILE_PATH" ] && [ ! -L "$FILE_PATH" ]; then
        LOGW "File not found: ${FILE_PATH//$WORK_DIR/}"
        return 0
    fi

    local IS_DIR=false
    [ -d "$FILE_PATH" ] && IS_DIR=true

    LOG "- Deleting ${FILE_PATH//$WORK_DIR/}"
    rm -rf "$FILE_PATH"

    local PATTERN="${FILE//\//\\/}"
    [ "$PARTITION" != "system" ] && PATTERN="$PARTITION\/$PATTERN"
    sed -i "/^$PATTERN /d" "$WORK_DIR/configs/fs_config-$PARTITION"
    if $IS_DIR; then
        sed -i "/^$PATTERN\//d" "$WORK_DIR/configs/fs_config-$PARTITION"
    fi

    PATTERN="$(_HANDLE_SPECIAL_CHARS "$FILE")"
    PATTERN="${PATTERN//\\/\\\\}"
    PATTERN="${PATTERN//\//\\/}"
    [ "$PARTITION" != "system" ] && PATTERN="$PARTITION\/$PATTERN"
    sed -i "/^\/$PATTERN /d" "$WORK_DIR/configs/file_context-$PARTITION"
    if $IS_DIR; then
        sed -i "/^\/$PATTERN\//d" "$WORK_DIR/configs/file_context-$PARTITION"
    fi

    if [[ "$FILE" == *".so" ]]; then
        while IFS= read -r f; do
            sed -i "/$(basename "$FILE")/d" "$f"
        done < <(grep -l "$(basename "$FILE")" "$WORK_DIR/system/system/etc/public.libraries"*.txt)
    fi

    return 0
}

# ENSURE_WORK_DIR_METADATA <partition> <file/dir>
# Ensures the supplied entry has both fs_config and file_context metadata in work dir.
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
EVAL()
{
    _CHECK_NON_EMPTY_PARAM "CMD" "$1" || return 1

    local CMD="$1"

    local OUT
    OUT="$(eval "$CMD" 2>&1)"
    # shellcheck disable=SC2181,SC2291
    if [ $? -ne 0 ]; then
        LOGE "Command returned a non-zero exit code\n"
        echo -e    '\033[0;31m'"$CMD"'\033[0m\n' >&2
        echo -n -e '\033[0;33m' >&2
        echo -n    "$OUT" >&2
        echo -e    '\033[0m' >&2
        return 1
    fi

    return 0
}

# GET_PROP "<partition>/<file>" "<prop>"
# Returns the supplied prop value, partition/file can be omitted.
GET_PROP()
{
    local FILES
    if [[ "$1" == *".prop" ]]; then
        FILES="$1"
        shift
    else
        FILES="$(_GET_PROP_FILES_PATH "$1")"
        if IS_VALID_PARTITION_NAME "$1"; then
            shift
        fi
    fi

    _CHECK_NON_EMPTY_PARAM "PROP" "$1" || return 1

    local PROP="$1"
    # shellcheck disable=SC2086
    cat $FILES 2> /dev/null | sed -n "s/^$PROP=//p" | head -n 1
}

# IS_SPARSE_IMAGE <file>
# Returns whether or not the supplied file is a valid sparse image.
IS_SPARSE_IMAGE()
{
    _CHECK_NON_EMPTY_PARAM "FILE" "$1" || exit 1

    local FILE="$1"

    if [ ! -f "$FILE" ]; then
        LOGE "File not found: ${FILE//$SRC_DIR\//}"
        return 1
    fi

    # https://android.googlesource.com/platform/system/core/+/refs/tags/android-15.0.0_r1/libsparse/sparse_format.h#39
    [[ "$(READ_BYTES_AT "$FILE" "0" "4")" == "ed26ff3a" ]]
}

# IS_VALID_PARTITION_NAME <partition>
# Returns whether or not the supplied partition name is valid.
IS_VALID_PARTITION_NAME()
{
    local PARTITION="$1"
    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/common.py#131
    [[ "$PARTITION" == "system" ]] || [[ "$PARTITION" == "vendor" ]] || [[ "$PARTITION" == "product" ]] || \
        [[ "$PARTITION" == "system_ext" ]] || [[ "$PARTITION" == "odm" ]] || [[ "$PARTITION" == "vendor_dlkm" ]] || \
        [[ "$PARTITION" == "odm_dlkm" ]] || [[ "$PARTITION" == "system_dlkm" ]] || [[ "$PARTITION" == "optics" ]] || [[ "$PARTITION" == "prism" ]]
}

# SET_METADATA <partition> <file/dir> <user> <group> <mode> <label>
# Adds the supplied file/directory entry attrs in fs_config/file_context.
SET_METADATA()
{
    _CHECK_NON_EMPTY_PARAM "PARTITION" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "ENTRY" "$2" || return 1
    _CHECK_NON_EMPTY_PARAM "USER" "$3" || return 1
    _CHECK_NON_EMPTY_PARAM "GROUP" "$4" || return 1
    _CHECK_NON_EMPTY_PARAM "MODE" "$5" || return 1
    _CHECK_NON_EMPTY_PARAM "LABEL" "$6" || return 1

    local PARTITION="$1"
    local ENTRY="$2"
    local USER="$3"
    local GROUP="$4"
    local MODE="$5"
    local LABEL="$6"

    if ! IS_VALID_PARTITION_NAME "$PARTITION"; then
        LOGE "\"$PARTITION\" is not a valid partition name"
        return 1
    fi

    while [[ "${ENTRY:0:1}" == "/" ]]; do
        ENTRY="${ENTRY:1}"
    done

    [ "$PARTITION" != "system" ] && [[ "$ENTRY" != "$PARTITION/"* ]] && ENTRY="$PARTITION/$ENTRY"

    LOG "- Adding metadata for /$ENTRY (uid:$USER gid:$GROUP mode:$MODE selabel:$LABEL)"

    local PATTERN
    PATTERN="${ENTRY//\//\\/}"
    sed -i "/^$PATTERN /d" "$WORK_DIR/configs/fs_config-$PARTITION"

    echo "$ENTRY $USER $GROUP $MODE capabilities=0x0" >> "$WORK_DIR/configs/fs_config-$PARTITION"

    PATTERN="$(_HANDLE_SPECIAL_CHARS "$ENTRY")"
    PATTERN="${PATTERN//\\/\\\\}"
    PATTERN="${PATTERN//\//\\/}"
    sed -i "/^\/$PATTERN /d" "$WORK_DIR/configs/file_context-$PARTITION"

    echo "/$(_HANDLE_SPECIAL_CHARS "$ENTRY") $LABEL" >> "$WORK_DIR/configs/file_context-$PARTITION"

    return 0
}
