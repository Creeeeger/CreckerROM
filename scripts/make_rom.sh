#!/usr/bin/env bash
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

set -e

# [
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1
source "$SRC_DIR/scripts/utils/module_utils.sh" || exit 1

FORCE=false
BUILD_ROM=false
TARGET_BUILD_KERNEL_ONLY="${TARGET_BUILD_KERNEL_ONLY:-false}"
if [ "$TARGET_BUILD_KERNEL_ONLY" != "true" ] && [ "$TARGET_BUILD_KERNEL_ONLY" != "false" ]; then
    LOGE "TARGET_BUILD_KERNEL_ONLY must be true or false (got: $TARGET_BUILD_KERNEL_ONLY)"
    exit 1
fi

START_TIME="$(date +%s)"

SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

GET_WORK_DIR_HASH()
{
    local TREE_HASH
    local OPTS_HASH
    TREE_HASH="$(
        find "$SRC_DIR/unica" "$SRC_DIR/target/$TARGET_CODENAME" -type f -print0 | \
            sort -z | xargs -0 sha1sum | sha1sum | cut -d " " -f 1
    )"

    # Include buildenv-generated options that impact the work dir but aren't part of the source tree.
    OPTS_HASH="$(
        printf '%s\n' \
            "FORCE_EXT4_IMAGES=${FORCE_EXT4_IMAGES:-false}" \
            "TARGET_ENABLE_ENCRYPTION=${TARGET_ENABLE_ENCRYPTION:-false}" \
            "ROM_DEBLOAT_LEVEL=${ROM_DEBLOAT_LEVEL:-default}" | \
            sha1sum | cut -d " " -f 1
    )"

    printf '%s\n' "${TREE_HASH}${OPTS_HASH}" | sha1sum | cut -d " " -f 1
}

PREPARE_REQUIRED_FIRMWARE()
{
    if [ ! -f "$FW_DIR/$SOURCE_FIRMWARE_PATH/.extracted" ] || [ ! -f "$FW_DIR/$TARGET_FIRMWARE_PATH/.extracted" ]; then
        if [ ! -f "$ODIN_DIR/$SOURCE_FIRMWARE_PATH/.downloaded" ] || [ ! -f "$ODIN_DIR/$TARGET_FIRMWARE_PATH/.downloaded" ]; then
            LOG_STEP_IN true "Downloading required firmwares"
            "$SRC_DIR/scripts/download_fw.sh" || exit 1
            LOG_STEP_OUT
        fi
        LOG_STEP_IN true "Extracting required firmwares"
        "$SRC_DIR/scripts/extract_fw.sh" || exit 1
        LOG_STEP_OUT
    fi
}

FIND_KERNEL_BUILD_MODULE()
{
    local CONFIGURED_PATH="${TARGET_KERNEL_BUILD_MODULE_PATH:-none}"
    local MODULE_PROP
    local MODULE_ID
    local MATCH=""

    if [ "$CONFIGURED_PATH" != "none" ]; then
        [[ "$CONFIGURED_PATH" == /* ]] || CONFIGURED_PATH="$SRC_DIR/$CONFIGURED_PATH"
        [ -f "$CONFIGURED_PATH/customize.sh" ] || {
            LOGE "Configured kernel build module does not contain customize.sh: $CONFIGURED_PATH"
            return 1
        }
        echo "$CONFIGURED_PATH"
        return 0
    fi

    for MODULE_PROP in "$SRC_DIR/platform/$TARGET_PLATFORM/patches"/*/module.prop; do
        [ -f "$MODULE_PROP" ] || continue
        MODULE_ID="$(sed -n 's/^id=//p' "$MODULE_PROP" | head -n 1)"
        case "$MODULE_ID" in
            *krnl*)
                if [ -n "$MATCH" ]; then
                    LOGE "Multiple kernel build modules found for $TARGET_PLATFORM. Set TARGET_KERNEL_BUILD_MODULE_PATH."
                    return 1
                fi
                MATCH="$(dirname "$MODULE_PROP")"
                ;;
        esac
    done

    [ -n "$MATCH" ] || {
        LOGE "No kernel build module found for $TARGET_PLATFORM. Set TARGET_KERNEL_BUILD_MODULE_PATH."
        return 1
    }
    [ -f "$MATCH/customize.sh" ] || {
        LOGE "Kernel build module does not contain customize.sh: $MATCH"
        return 1
    }

    echo "$MATCH"
}

BUILD_KERNEL_TEST_IMAGES()
{
    local MODULE_PATH
    local IMAGE

    MODULE_PATH="$(FIND_KERNEL_BUILD_MODULE)" || exit 1
    mkdir -p "$WORK_DIR/kernel"

    LOG_STEP_IN true "Building kernel test images"
    (
        source "$MODULE_PATH/customize.sh"
    ) || exit 1
    LOG_STEP_OUT

    for IMAGE in boot dtbo; do
        [ -f "$WORK_DIR/kernel/$IMAGE.img" ] || {
            LOGE "Kernel build did not produce $IMAGE.img"
            exit 1
        }
    done
}

PREPARE_SCRIPT()
{
    while [ "$#" != 0 ]; do
        case "$1" in
            "-f" | "--force")
                FORCE=true
                ;;
            *)
                echo "Usage: make_rom [options]"
                echo " -f, --force : Force build"
                exit 1
                ;;
        esac

        shift
    done
}

PRINT_BUILD_OUTCOME()
{
    local EXIT_CODE="$?"
    local END_TIME
    local ESTIMATED

    END_TIME="$(date +%s)"
    ESTIMATED="$((END_TIME - START_TIME))"

    if [ "$EXIT_CODE" != "0" ]; then
        echo -n -e '\n\033[1;31m'"Build failed "
    else
        echo -n -e '\n\033[1;32m'"Build completed "
    fi
    echo -e "in $((ESTIMATED / 3600))hrs $(((ESTIMATED / 60) % 60))min $((ESTIMATED % 60))sec."'\033[0m\n'
}

PRINT_USAGE()
{
    echo "Usage: make_rom [options]" >&2
    echo " -f, --force : Force ROM build" >&2
}

# ]

PREPARE_SCRIPT "$@"

if [ "${TARGET_BUILD_MODE:-normal}" = "rollback" ]; then
    trap 'PRINT_BUILD_OUTCOME' EXIT
    trap 'echo' INT

    LOG_STEP_IN true "Preparing signing keys"
    PRINT_SHARED_SIGNING_KEY_INFO || exit 1
    LOG_STEP_OUT

    LOG_STEP_IN true "Building rollback firmware"
    "$SRC_DIR/scripts/internal/build_rollback_firmware.sh" || exit 1
    LOG_STEP_OUT
    exit 0
fi

if $TARGET_BUILD_KERNEL_ONLY; then
    BUILD_ROM=false
elif $FORCE; then
    BUILD_ROM=true
else
    if [ -f "$WORK_DIR/.completed" ]; then
        if [[ "$(cat "$WORK_DIR/.completed")" == "$(GET_WORK_DIR_HASH)" ]]; then
            LOGW "No changes have been detected in the build environment"
            BUILD_ROM=false
        else
            LOGW "Changes detected in the build environment"
            BUILD_ROM=true
        fi
    else
        BUILD_ROM=true
    fi
fi

trap 'PRINT_BUILD_OUTCOME' EXIT
trap 'echo' INT

LOG_STEP_IN true "Preparing signing keys"
PRINT_SHARED_SIGNING_KEY_INFO || exit 1
LOG_STEP_OUT

if $BUILD_ROM; then
    [ -d "$APKTOOL_DIR" ] && rm -rf "$APKTOOL_DIR"
    [ -f "$WORK_DIR/.completed" ] && rm -f "$WORK_DIR/.completed"

    PREPARE_REQUIRED_FIRMWARE

    LOG_STEP_IN true "Creating work dir"
    "$SRC_DIR/scripts/internal/create_work_dir.sh" || exit 1
    LOG_STEP_OUT

    if [ -d "$SRC_DIR/target/$TARGET_CODENAME/pre_patches" ]; then
        LOG_STEP_IN true "Applying pre patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/target/$TARGET_CODENAME/pre_patches" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$SRC_DIR/unica/patches" ]; then
        LOG_STEP_IN true "Applying ROM patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/unica/patches" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$SRC_DIR/platform/$TARGET_PLATFORM/patches" ]; then
        LOG_STEP_IN true "Applying platform patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/platform/$TARGET_PLATFORM/patches" || exit 1
        LOG_STEP_OUT
    fi
    if [ -d "$SRC_DIR/target/$TARGET_CODENAME/patches" ]; then
        LOG_STEP_IN true "Applying device patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/target/$TARGET_CODENAME/patches" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$SRC_DIR/unica/mods" ]; then
        LOG_STEP_IN true "Applying ROM mods"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/unica/mods" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$APKTOOL_DIR" ]; then
        LOG_STEP_IN true "Building APKs/JARs"

        while IFS= read -r f; do
            f="${f/$APKTOOL_DIR\//}"
            PARTITION="$(cut -d "/" -f 1 -s <<< "$f")"
            if [[ "$PARTITION" == "system" ]]; then
                "$SRC_DIR/scripts/apktool.sh" b "system" "$f" &
            else
                "$SRC_DIR/scripts/apktool.sh" b "$PARTITION" "$(cut -d "/" -f 2- -s <<< "$f")" &
            fi
        done < <(find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \))

        # shellcheck disable=SC2046
        wait $(jobs -p) || exit 1

        LOG_STEP_OUT
    fi

    echo -n "$(GET_WORK_DIR_HASH)" > "$WORK_DIR/.completed"
fi

if $TARGET_BUILD_KERNEL_ONLY; then
    PREPARE_REQUIRED_FIRMWARE
    BUILD_KERNEL_TEST_IMAGES
fi

if [ -n "$GITHUB_ACTIONS" ]; then
    bash "$SRC_DIR/scripts/cleanup.sh" fw kernel
fi

LOG_STEP_IN true "Creating flash packages"
"$SRC_DIR/scripts/internal/build_packages.sh" || exit 1
LOG_STEP_OUT

exit 0
