# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

RESTORE_ARM32_APP_SUPPORT()
{
    case "$TARGET_CODENAME" in
        x1s|y2s|z3s|r8s|c1s|c2s) ;;
        *) return 0 ;;
    esac
    if [[ "$TARGET_PLATFORM" != "exynos990" || "$TARGET_SINGLE_SYSTEM_IMAGE" != "essi" ]]; then
        ABORT "32-bit app support requires an Exynos990 essi target."
        return 1
    fi

    local PREBUILT="$SRC_DIR/prebuilts/samsung/r11sxxx_32bit"
    python3 "$MODPATH/validate.py" "$PREBUILT" "$WORK_DIR" || return 1

    LOG_STEP_IN "- Restoring the committed S23 FE Android 15 ARM32 runtime"
    ADD_TO_WORK_DIR "$PREBUILT" "system" "system/lib" || return 1
    ADD_TO_WORK_DIR "$PREBUILT" "system" "system/bin/app_process32" || return 1
    ADD_TO_WORK_DIR "$PREBUILT" "system" "system/bin/boringssl_self_test32" || return 1
    local APEX
    for APEX in "$PREBUILT/system/apex/"*.apex; do
        ADD_TO_WORK_DIR "$PREBUILT" "system" "system/apex/${APEX##*/}" || return 1
    done
    SET_METADATA "system" "system/bin/app_process32" 0 0 755 "u:object_r:zygote_exec:s0"
    SET_METADATA "system" "system/bin/bootstrap/linker" 0 0 755 "u:object_r:system_linker_exec:s0"
    SET_METADATA "system" "system/bin/boringssl_self_test32" 0 2000 755 "u:object_r:boringssl_self_test_exec:s0"

    local FILE MODE
    for FILE in "$WORK_DIR/system/system/lib/bootstrap" "$WORK_DIR/system/system/lib/bootstrap/"*; do
        [ -e "$FILE" ] || [ -L "$FILE" ] || continue
        MODE=644
        [ ! -d "$FILE" ] || MODE=755
        SET_METADATA "system" "${FILE#"$WORK_DIR/system/"}" 0 0 "$MODE" "u:object_r:system_bootstrap_lib_file:s0"
    done
    LOG_STEP_OUT

    LOG_STEP_IN "- Enabling the secondary app zygote and ARM32 ABIs"
    # SET_PROP treats an empty existing value as absent. Remove empty ABI
    # declarations first so each property has a single unambiguous value.
    local PARTITION PROP_FILE PREFIX
    for PARTITION in system vendor; do
        while IFS= read -r PROP_FILE; do
            [ -f "$PROP_FILE" ] || continue
            sed -i '/^ro\..*cpu\.abilist32=$/d' "$PROP_FILE"
        done < <(_GET_PROP_FILES_PATH "$PARTITION")
    done

    for PREFIX in ro.product.cpu ro.system.product.cpu; do
        SET_PROP "system" "$PREFIX.abilist" "arm64-v8a,armeabi-v7a,armeabi"
        SET_PROP "system" "$PREFIX.abilist32" "armeabi-v7a,armeabi"
        SET_PROP "system" "$PREFIX.abilist64" "arm64-v8a"
    done
    SET_PROP "vendor" "ro.vendor.product.cpu.abilist" "arm64-v8a,armeabi-v7a,armeabi"
    SET_PROP "vendor" "ro.vendor.product.cpu.abilist32" "armeabi-v7a,armeabi"
    SET_PROP "vendor" "ro.vendor.product.cpu.abilist64" "arm64-v8a"
    SET_PROP "vendor" "ro.zygote" "zygote64_32"
    # The 64-bit compiler can compile both instruction sets, including ARM32
    # boot images for this ROM's own patched framework jars on first boot.
    SET_PROP "vendor" "dalvik.vm.dex2oat64.enabled" "true"
    LOG_STEP_OUT
}

RESTORE_ARM32_APP_SUPPORT
