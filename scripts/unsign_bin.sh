#!/usr/bin/env bash
#
# Copyright (C) 2023 Salvo Giangreco
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
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1

UPSTREAM_AVBTOOL_PATH="$SRC_DIR/platform_external_avb-master/avbtool.py"
ALLOW_LEGACY_UNSIGN_BIN="${ALLOW_LEGACY_UNSIGN_BIN:-false}"
AVBTOOL_CMD=()

SETUP_AVBTOOL()
{
    if [ ! -f "$UPSTREAM_AVBTOOL_PATH" ]; then
        LOGE "Official AVB reference not found: $UPSTREAM_AVBTOOL_PATH"
        exit 1
    fi
    if ! command -v python3 &> /dev/null; then
        LOGE "python3 is required to execute $UPSTREAM_AVBTOOL_PATH"
        exit 1
    fi
    AVBTOOL_CMD=("$(command -v python3)" "$UPSTREAM_AVBTOOL_PATH")
    "${AVBTOOL_CMD[@]}" version &> /dev/null || {
        LOGE "Failed to execute official AVB reference: $UPSTREAM_AVBTOOL_PATH"
        exit 1
    }
}

RUN_AVBTOOL()
{
    "${AVBTOOL_CMD[@]}" "$@"
}
# ]

if [ "$#" == 0 ]; then
    echo "Usage: unsign_bin <image> (<image>...)" >&2
    exit 1
fi

if [ "${TARGET_ALLOW_LEGACY_UNSIGNED_BUILD:-false}" != "true" ] && [ "$ALLOW_LEGACY_UNSIGN_BIN" != "true" ]; then
    LOGE "scripts/unsign_bin.sh is an insecure legacy path. Re-run only with TARGET_ALLOW_LEGACY_UNSIGNED_BUILD=\"true\" or ALLOW_LEGACY_UNSIGN_BIN=\"true\"."
    exit 1
fi

SETUP_AVBTOOL
LOGW "Using insecure legacy unsign path. Final build artifacts should use the official custom AVB re-sign flow instead."

while [ "$#" != 0 ]; do
    if [ ! -f "$1" ]; then
        LOGE "File not found: $1"
        exit 1
    else
        if RUN_AVBTOOL info_image --image "$1" &> /dev/null; then
            LOG "- Removing AVB footer signature from $(basename "$1")"
            RUN_AVBTOOL erase_footer --image "$1" || exit 1
        fi
        if head "$1" | grep -q "SignerVer"; then
            LOG "- Removing Samsung header signature from $(basename "$1")"
            dd if="/dev/zero" of="$1" bs=256 seek=0 count=1 conv=notrunc &> /dev/null
            dd if="/dev/zero" of="$1" bs=256 seek=3 count=1 conv=notrunc &> /dev/null
        fi
        if tail "$1" | grep -q "SignerVer02"; then
            LOG "- Removing Samsung footer signature from $(basename "$1")"
            truncate -s -512 "$1"
        fi
        if tail "$1" | grep -q "SignerVer03"; then
            LOG "- Removing Samsung footer signature from $(basename "$1")"
            truncate -s -784 "$1"
        fi
    fi

    shift
done

exit 0
