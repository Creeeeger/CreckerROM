# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

_CHECK_NON_EMPTY_PARAM "ROM_SECURITY_PATCH_LEVEL" "${ROM_SECURITY_PATCH_LEVEL:-}" || return 1
python3 "$SRC_DIR/scripts/internal/boot_patch_level.py" \
    --patch-level "$ROM_SECURITY_PATCH_LEVEL" > /dev/null || return 1

if [ "$ROM_SECURITY_PATCH_LEVEL" = "preserve" ]; then
    return 0
fi

# Change reported metadata only; this does not apply Android security fixes.
SET_PROP "system" "ro.build.version.security_patch" "$ROM_SECURITY_PATCH_LEVEL"
SET_PROP "vendor" "ro.vendor.build.security_patch" "$ROM_SECURITY_PATCH_LEVEL"

# Keep alternate vendor property names in sync when present in the firmware.
SET_PROP_IF_DIFF "vendor" "ro.vendor.build.version.security_patch" "$ROM_SECURITY_PATCH_LEVEL"
SET_PROP_IF_DIFF "vendor" "ro.build.version.security_patch" "$ROM_SECURITY_PATCH_LEVEL"
