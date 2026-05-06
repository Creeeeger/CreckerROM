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
# shellcheck disable=SC1007,SC2164
# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/envsetup.sh#18
_GET_SRC_DIR()
{
    local TOPFILE="unica/configs/version.sh"
    if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$TOPFILE" ]; then
        # The following circumlocution ensures we remove symlinks from SRC_DIR.
        (cd "$SRC_DIR"; PWD= /bin/pwd)
    else
        if [ -f "$TOPFILE" ]; then
            # The following circumlocution (repeated below as well) ensures
            # that we record the true directory name and not one that is
            # faked up with symlink names.
            PWD= /bin/pwd
        else
            local HERE="$PWD"
            local T=
            while [ \( ! \( -f "$TOPFILE" \) \) ] && [ \( "$PWD" != "/" \) ]; do
                \cd ..
                T="$(PWD= /bin/pwd -P)"
            done
            \cd "$HERE"
            if [ -f "$T/$TOPFILE" ]; then
                echo "$T"
            fi
        fi
    fi
}

_PRINT_USAGE()
{
    echo "Usage: source buildenv.sh [options] <target>" >&2
    echo "Options:" >&2
    echo " --debug : Enable verbose debug logs" >&2
    echo " --official : Mark the generated config/build as official" >&2
    echo " --unofficial : Mark the generated config/build as unofficial" >&2
    echo " --ext4-images : Force EROFS target partitions to be built as ext4" >&2
    echo " --encrypt : Enable data encryption in the generated config" >&2
    echo " --debloat <default|none|ultra> : Select debloat level (default: current debloat)" >&2
    echo " --no-debloat : Alias for --debloat none" >&2
    echo " --ultra-debloat : Alias for --debloat ultra" >&2
    echo " --zip : Build the flashable zip in addition to the default Odin package" >&2
    echo " --heimdall-only : Build only the Heimdall image folder" >&2
    echo " --avb : Enable AVB signing, image signing and vbmeta creation" >&2
    echo "Available devices:" >&2
    printf '%s\n' "${TARGETS[@]}" >&2
}

# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/envsetup.sh#806
croot()
{
    if [ -d "$SRC_DIR" ]; then
        if [ "$1" ]; then
            cd "$SRC_DIR/$1"
        else
            cd "$SRC_DIR"
        fi
    else
        echo "Couldn't locate the top of the tree. Try setting SRC_DIR."
        return 1
    fi
}

run_cmd()
{
    local CMD="$1"

    if [ -x "$SRC_DIR/scripts/$CMD.sh" ]; then
        shift
        mkdir -p "$(dirname "$WORK_DIR")"
        (set -o pipefail; "$SRC_DIR/scripts/$CMD.sh" "$@" 2>&1 | tee \
            >(sed -r -e "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2};?)?)?[mGK]//g" -e "/#/d" > "$(dirname "$WORK_DIR")/$CMD-$(date +%Y%m%d_%H%M%S).log"))
        return $?
    else
        local CMDS=()
        while IFS= read -r f; do
            CMDS+=("$f")
        done < <(find "$SRC_DIR/scripts" -maxdepth 1 ! -type d -exec basename {} \; | sort | sed "s/.sh//")

        if [ "$CMD" ]; then
            if [[ "$CMD" == "--help" ]] || [[ "$CMD" == "-h" ]]; then
                echo "Available cmds:" >&2
                for c in "${CMDS[@]}"; do
                    echo -e '\n\033[1;37m'"$c:"'\033[0m'
                    "$SRC_DIR/scripts/$c.sh" --help
                done
                return 0
            else
                echo -e '\033[0;31m'"\"$CMD\" is not a valid cmd."'\033[0m' >&2
            fi
        fi

        echo "Available cmds:" >&2
        printf '%s\n' "${CMDS[@]}" >&2
        return 1
    fi
}

_CLEAR_GENERATED_CONFIG_ENV()
{
    local VAR

    while IFS= read -r VAR; do
        case "$VAR" in
            SOURCE_*|TARGET_*|ROM_VERSION|ROM_CODENAME|ROM_DISPLAY_NAME|ROM_TYPE|ROM_BUILD_TIMESTAMP|ROM_IS_OFFICIAL)
                unset "$VAR"
                ;;
        esac
    done < <(set | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p')
}

alias unica=run_cmd
alias extremerom=run_cmd
alias erom=run_cmd
alias m="./scripts/make_rom.sh"

# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/envsetup.sh#806
croot()
{
    if [ -d "$SRC_DIR" ]; then
        if [ "$1" ]; then
            cd "$SRC_DIR/$1"
        else
            cd "$SRC_DIR"
        fi
    else
        echo "Couldn't locate the top of the tree. Try setting SRC_DIR."
        return 1
    fi
}
# ]

SRC_DIR="$(_GET_SRC_DIR)"
if [ ! "$SRC_DIR" ]; then
    echo "Couldn't locate the top of the tree. Always source buildenv.sh from the root of the tree." >&2
    return 1
fi

unset -f _GET_SRC_DIR

export DEBUG=false
export FORCE_EXT4_IMAGES="${FORCE_EXT4_IMAGES:-false}"
export ROM_ENABLE_ENCRYPTION="${ROM_ENABLE_ENCRYPTION:-false}"
export ROM_DEBLOAT_LEVEL="${ROM_DEBLOAT_LEVEL:-default}"
export ROM_BUILD_FLASHABLE_ZIP="false"
export ROM_BUILD_HEIMDALL_ONLY="false"
export ROM_ENABLE_AVB="false"
export ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS="true"
export ROM_IS_OFFICIAL="${ROM_IS_OFFICIAL:-true}"
export SRC_DIR
export OUT_DIR="$SRC_DIR/out"
export TMP_DIR="$OUT_DIR/tmp"
export KERNEL_TMP_DIR="$OUT_DIR/kernel_tmp"
export ODIN_DIR="$OUT_DIR/odin"
export FW_DIR="$OUT_DIR/fw"
export TOOLS_DIR="$OUT_DIR/tools"
export PATH="$TOOLS_DIR/bin:$PATH"

TARGETS=()
while IFS= read -r t; do
    TARGETS+=("$t")
done < <(find "$SRC_DIR/target" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)

while [[ "$1" == "-"* ]]; do
    if [[ "$1" == "--debug" ]]; then
        export DEBUG=true
    elif [[ "$1" == "--official" ]]; then
        export ROM_IS_OFFICIAL="true"
    elif [[ "$1" == "--unofficial" ]]; then
        export ROM_IS_OFFICIAL="false"
    elif [[ "$1" == "--ext4-images" ]]; then
        export FORCE_EXT4_IMAGES=true
    elif [[ "$1" == "--encrypt" ]]; then
        export ROM_ENABLE_ENCRYPTION="true"
    elif [[ "$1" == "--no-debloat" ]]; then
        export ROM_DEBLOAT_LEVEL="none"
    elif [[ "$1" == "--ultra-debloat" ]]; then
        export ROM_DEBLOAT_LEVEL="ultra"
    elif [[ "$1" == "--debloat" ]]; then
        shift
        if [ ! "$1" ]; then
            echo "--debloat requires an argument (default|none|ultra)" >&2
            _PRINT_USAGE
            return 1
        fi
        export ROM_DEBLOAT_LEVEL="$1"
    elif [[ "$1" == "--debloat="* ]]; then
        export ROM_DEBLOAT_LEVEL="${1#--debloat=}"
    elif [[ "$1" == "--zip" ]]; then
        export ROM_BUILD_FLASHABLE_ZIP="true"
    elif [[ "$1" == "--heimdall-only" ]]; then
        export ROM_BUILD_HEIMDALL_ONLY="true"
    elif [[ "$1" == "--avb" ]]; then
        export ROM_ENABLE_AVB="true"
    elif [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        _PRINT_USAGE
        return 0
    else
        echo "Unknown option: $1" >&2
        _PRINT_USAGE
        return 1
    fi
    shift
done

if [[ "$ROM_DEBLOAT_LEVEL" != "default" ]] && \
        [[ "$ROM_DEBLOAT_LEVEL" != "none" ]] && \
        [[ "$ROM_DEBLOAT_LEVEL" != "ultra" ]]; then
    echo "Invalid --debloat value: $ROM_DEBLOAT_LEVEL (expected: default|none|ultra)" >&2
    _PRINT_USAGE
    return 1
fi

if [[ "$ROM_BUILD_FLASHABLE_ZIP" != "true" ]] && \
        [[ "$ROM_BUILD_FLASHABLE_ZIP" != "false" ]]; then
    echo "Invalid zip flag state: $ROM_BUILD_FLASHABLE_ZIP (expected: true|false)" >&2
    _PRINT_USAGE
    return 1
fi

if [[ "$ROM_BUILD_HEIMDALL_ONLY" != "true" ]] && \
        [[ "$ROM_BUILD_HEIMDALL_ONLY" != "false" ]]; then
    echo "Invalid heimdall-only flag state: $ROM_BUILD_HEIMDALL_ONLY (expected: true|false)" >&2
    _PRINT_USAGE
    return 1
fi

if [[ "$ROM_BUILD_HEIMDALL_ONLY" == "true" ]]; then
    export ROM_BUILD_FLASHABLE_ZIP="false"
fi

if [[ "$ROM_ENABLE_ENCRYPTION" != "true" ]] && \
        [[ "$ROM_ENABLE_ENCRYPTION" != "false" ]]; then
    echo "Invalid encryption flag state: $ROM_ENABLE_ENCRYPTION (expected: true|false)" >&2
    _PRINT_USAGE
    return 1
fi

if [[ "$ROM_ENABLE_AVB" != "true" ]] && \
        [[ "$ROM_ENABLE_AVB" != "false" ]]; then
    echo "Invalid AVB flag state: $ROM_ENABLE_AVB (expected: true|false)" >&2
    _PRINT_USAGE
    return 1
fi

if [[ "$ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "true" ]] && \
        [[ "$ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS" != "false" ]]; then
    echo "Invalid AVB vbmeta partition descriptor state: $ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS (expected: true|false)" >&2
    _PRINT_USAGE
    return 1
fi

if [[ "$ROM_IS_OFFICIAL" != "true" ]] && \
        [[ "$ROM_IS_OFFICIAL" != "false" ]]; then
    echo "Invalid official flag state: $ROM_IS_OFFICIAL (expected: true|false)" >&2
    _PRINT_USAGE
    return 1
fi

if [ "$#" -ne 1 ]; then
    echo "No target specified. Please choose from the available devices below:"

    select SELECTED_TARGET in "${TARGETS[@]}"; do
        if [ -n "$SELECTED_TARGET" ]; then
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
else
    SELECTED_TARGET="$1"
fi

if [ ! -d "$SRC_DIR/target/$SELECTED_TARGET" ]; then
    echo "\"$SELECTED_TARGET\" is not a valid device." >&2
    _PRINT_USAGE
    return 1
fi

unset -f _PRINT_USAGE

export APKTOOL_DIR="$OUT_DIR/target/$SELECTED_TARGET/apktool"
export WORK_DIR="$OUT_DIR/target/$SELECTED_TARGET/work_dir"

mkdir -p "$OUT_DIR/target/$SELECTED_TARGET"
# shellcheck disable=SC2046
_SAVED_FORCE_EXT4_IMAGES="$FORCE_EXT4_IMAGES"
_SAVED_ROM_ENABLE_ENCRYPTION="$ROM_ENABLE_ENCRYPTION"
_SAVED_ROM_DEBLOAT_LEVEL="$ROM_DEBLOAT_LEVEL"
_SAVED_ROM_BUILD_FLASHABLE_ZIP="$ROM_BUILD_FLASHABLE_ZIP"
_SAVED_ROM_BUILD_HEIMDALL_ONLY="$ROM_BUILD_HEIMDALL_ONLY"
_SAVED_ROM_ENABLE_AVB="$ROM_ENABLE_AVB"
_SAVED_ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS="$ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS"
_SAVED_ROM_IS_OFFICIAL="$ROM_IS_OFFICIAL"
_CLEAR_GENERATED_CONFIG_ENV
export FORCE_EXT4_IMAGES="$_SAVED_FORCE_EXT4_IMAGES"
export ROM_ENABLE_ENCRYPTION="$_SAVED_ROM_ENABLE_ENCRYPTION"
export ROM_DEBLOAT_LEVEL="$_SAVED_ROM_DEBLOAT_LEVEL"
export ROM_BUILD_FLASHABLE_ZIP="$_SAVED_ROM_BUILD_FLASHABLE_ZIP"
export ROM_BUILD_HEIMDALL_ONLY="$_SAVED_ROM_BUILD_HEIMDALL_ONLY"
export ROM_ENABLE_AVB="$_SAVED_ROM_ENABLE_AVB"
export ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS="$_SAVED_ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS"
export ROM_IS_OFFICIAL="$_SAVED_ROM_IS_OFFICIAL"
unset _SAVED_FORCE_EXT4_IMAGES
unset _SAVED_ROM_ENABLE_ENCRYPTION
unset _SAVED_ROM_DEBLOAT_LEVEL
unset _SAVED_ROM_BUILD_FLASHABLE_ZIP
unset _SAVED_ROM_BUILD_HEIMDALL_ONLY
unset _SAVED_ROM_ENABLE_AVB
unset _SAVED_ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS
unset _SAVED_ROM_IS_OFFICIAL
env -i \
    PATH="$PATH" \
    HOME="${HOME:-}" \
    USER="${USER:-}" \
    SHELL="${SHELL:-}" \
    DEBUG="$DEBUG" \
    SRC_DIR="$SRC_DIR" \
    OUT_DIR="$OUT_DIR" \
    FORCE_EXT4_IMAGES="$FORCE_EXT4_IMAGES" \
    ROM_ENABLE_ENCRYPTION="$ROM_ENABLE_ENCRYPTION" \
    ROM_DEBLOAT_LEVEL="$ROM_DEBLOAT_LEVEL" \
    ROM_BUILD_FLASHABLE_ZIP="$ROM_BUILD_FLASHABLE_ZIP" \
    ROM_BUILD_HEIMDALL_ONLY="$ROM_BUILD_HEIMDALL_ONLY" \
    ROM_ENABLE_AVB="$ROM_ENABLE_AVB" \
    ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS="$ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS" \
    ROM_IS_OFFICIAL="$ROM_IS_OFFICIAL" \
    "$SRC_DIR/scripts/internal/gen_config_file.sh" "$SELECTED_TARGET" || return 1
set -o allexport; source "$OUT_DIR/config.sh"; set +o allexport

unset TARGETS SELECTED_TARGET
unset -f _CLEAR_GENERATED_CONFIG_ENV

echo "=============================="
sed "/Automatically/d" "$OUT_DIR/config.sh"
echo "=============================="

return 0
