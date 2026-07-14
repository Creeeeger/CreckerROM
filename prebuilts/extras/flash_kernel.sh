#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v heimdall > /dev/null 2>&1; then
    echo "heimdall not found in PATH" >&2
    exit 1
fi

ARGS=()

ADD_IMAGE()
{
    local PARTITION="$1"
    local IMAGE="$2"

    [ -f "$IMAGE" ] || return 0
    ARGS+=("--$PARTITION" "$IMAGE")
}

ADD_IMAGE "DTBO" "dtbo.img"
ADD_IMAGE "BOOT" "boot.img"
ADD_IMAGE "VBMETA" "vbmeta.img"

if [ "${#ARGS[@]}" -eq 0 ]; then
    echo "No known Heimdall-flashable images found next to this script." >&2
    exit 1
fi

printf 'heimdall flash'
printf ' %q' "${ARGS[@]}" "$@"
printf '\n'

heimdall flash "${ARGS[@]}" "$@"
