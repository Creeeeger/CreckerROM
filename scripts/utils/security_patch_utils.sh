# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

GET_AVB_SECURITY_PATCH_LEVEL()
{
    local PATCH_LEVEL="${TARGET_AVB_VBMETA_SECURITY_PATCH_OVERRIDE:-${ROM_SECURITY_PATCH_LEVEL:-}}"
    if [ -z "$PATCH_LEVEL" ]; then
        PATCH_LEVEL="$(source "$SRC_DIR/unica/configs/version.sh" && printf '%s' "$ROM_SECURITY_PATCH_LEVEL")" || return 1
    fi
    python3 "$SRC_DIR/scripts/internal/boot_patch_level.py" --patch-level "$PATCH_LEVEL"
}

PREPARE_BOOT_PATCH_LEVEL()
{
    local PATCH_LEVEL
    PATCH_LEVEL="$(GET_AVB_SECURITY_PATCH_LEVEL)" || return 1
    python3 "$SRC_DIR/scripts/internal/boot_patch_level.py" \
        --patch-level "$PATCH_LEVEL" --images-dir "$1"
}
