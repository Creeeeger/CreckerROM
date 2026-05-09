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

ADD_IMAGE "BOOTLOADER" "sboot.bin"
ADD_IMAGE "PARAM" "param.bin"
ADD_IMAGE "UP_PARAM" "up_param.bin"
ADD_IMAGE "KEYSTORAGE" "keystorage.bin"
ADD_IMAGE "HARX" "harx.bin"
ADD_IMAGE "UH" "uh.bin"
ADD_IMAGE "UHCFG" "uhuh.bin"
ADD_IMAGE "DTBO" "dtbo.img"
ADD_IMAGE "DTB" "dtb.img"
ADD_IMAGE "INIT_BOOT" "init_boot.img"
ADD_IMAGE "VENDOR_BOOT" "vendor_boot.img"
ADD_IMAGE "BOOT" "boot.img"
ADD_IMAGE "RECOVERY" "recovery.img"
ADD_IMAGE "MISC" "misc.bin"
ADD_IMAGE "DQMDBG" "dqmdbg.img"
ADD_IMAGE "VBMETA" "vbmeta.img"
ADD_IMAGE "VBMETA_SAMSUNG" "vbmeta_samsung.img"

if [ -f "super.img" ]; then
    ADD_IMAGE "SUPER" "super.img"
else
    ADD_IMAGE "SYSTEM" "system.img"
    ADD_IMAGE "VENDOR" "vendor.img"
    ADD_IMAGE "PRODUCT" "product.img"
    ADD_IMAGE "SYSTEM_EXT" "system_ext.img"
    ADD_IMAGE "ODM" "odm.img"
    ADD_IMAGE "VENDOR_DLKM" "vendor_dlkm.img"
    ADD_IMAGE "ODM_DLKM" "odm_dlkm.img"
    ADD_IMAGE "SYSTEM_DLKM" "system_dlkm.img"
fi

ADD_IMAGE "PRISM" "prism.img"
ADD_IMAGE "OPTICS" "optics.img"
ADD_IMAGE "CACHE" "cache.img"
ADD_IMAGE "OMR" "omr.img"
ADD_IMAGE "LDFW" "ldfw.img"
ADD_IMAGE "TZSW" "tzsw.img"
ADD_IMAGE "TZAR" "tzar.img"
ADD_IMAGE "SSP" "ssp.img"

if [ "${#ARGS[@]}" -eq 0 ]; then
    echo "No known Heimdall-flashable images found next to this script." >&2
    exit 1
fi

printf 'heimdall flash'
printf ' %q' "${ARGS[@]}" "$@"
printf '\n'

heimdall flash "${ARGS[@]}" "$@"
