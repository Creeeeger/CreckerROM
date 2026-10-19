# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

RESTORE_ARM32_APP_SUPPORT()
{
    case "$TARGET_CODENAME" in
        x1s|y2s|z3s|r8s|c1s|c2s) ;;
        *)
            LOG "- ARM32 app support is only applied to S20/Note20 targets."
            return 0
            ;;
    esac
    if [[ "$TARGET_PLATFORM" != "exynos990" || "$TARGET_SINGLE_SYSTEM_IMAGE" != "essi" ]]; then
        ABORT "32-bit app support requires an Exynos990 essi target."
        return 1
    fi

    local BLOBS=(
        system/lib
        system/bin/app_process32
        system/bin/bootstrap/linker
        system/apex/com.android.runtime.apex
        system/apex/com.android.i18n.apex
        system/apex/com.google.android.adbd_compressed.apex
        system/apex/com.google.android.art_compressed.apex
        system/apex/com.google.android.conscrypt_compressed.apex
        system/apex/com.google.android.media_compressed.apex
        system/apex/com.google.android.mediaprovider_compressed.apex
        system/apex/com.google.android.neuralnetworks_compressed.apex
        system/apex/com.google.android.os.statsd_compressed.apex
        system/apex/com.google.android.tethering_compressed.apex
    )
    # Copy only from existing local firmware/prebuilt directories. This module
    # never downloads or extracts firmware and never imports an older ART stack.
    local SOURCES=("$FW_DIR/"* "$SRC_DIR/prebuilts/samsung/"*)
    [ -z "${COMPAT32_SOURCE_DIR:-}" ] || SOURCES=("$COMPAT32_SOURCE_DIR")
    local DONOR_DIR="" CANDIDATE SYSTEM_DIR PROP_FILE BLOB COMPLETE ROM_API
    ROM_API="$(GET_PROP "system" "ro.build.version.sdk")"
    [ -n "$ROM_API" ] || { ABORT "Missing ROM Android API level."; return 1; }
    for CANDIDATE in "${SOURCES[@]}"; do
        [ -d "$CANDIDATE" ] || continue
        SYSTEM_DIR="$CANDIDATE/system"
        [ ! -d "$SYSTEM_DIR/system" ] || SYSTEM_DIR+="/system"
        PROP_FILE="$SYSTEM_DIR/build.prop"
        [ -f "$PROP_FILE" ] || PROP_FILE="$CANDIDATE/compat32.prop"
        [ -f "$PROP_FILE" ] || continue
        [[ "$(GET_PROP "$PROP_FILE" "ro.build.version.sdk")" == "$ROM_API" ]] || continue
        [ -n "$(GET_PROP "$PROP_FILE" "ro.system.product.cpu.abilist32")" ] || continue
        [ -f "$CANDIDATE/fs_config-system" ] && [ -f "$CANDIDATE/file_context-system" ] || continue
        COMPLETE=true
        for BLOB in "${BLOBS[@]}"; do
            if [ ! -e "$SYSTEM_DIR/${BLOB#system/}" ] && [ ! -L "$SYSTEM_DIR/${BLOB#system/}" ] && \
                    [ ! -f "$SYSTEM_DIR/${BLOB#system/}.00" ]; then
                COMPLETE=false
                break
            fi
        done
        if $COMPLETE; then
            DONOR_DIR="$CANDIDATE"
            break
        fi
    done
    if [ -z "$DONOR_DIR" ]; then
        ABORT "No complete local ARM32 runtime for Android API $ROM_API found. Set COMPAT32_SOURCE_DIR to an existing compatible firmware/prebuilt directory."
        return 1
    fi

    LOG_STEP_IN "- Restoring ARM32 app support from local files: $DONOR_DIR"
    for BLOB in "${BLOBS[@]}"; do
        ADD_TO_WORK_DIR "$DONOR_DIR" "system" "$BLOB" || return 1
    done
    SET_METADATA "system" "system/bin/app_process32" 0 0 755 "u:object_r:zygote_exec:s0"
    SET_METADATA "system" "system/bin/bootstrap/linker" 0 0 755 "u:object_r:system_linker_exec:s0"

    # Enabling the ARM32 ABI makes init run this before starting zygote. The
    # stock launcher tests the restored libcrypto through its stable C API.
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/bin/boringssl_self_test32" \
        0 2000 755 "u:object_r:boringssl_self_test_exec:s0" || return 1
    SET_METADATA "system" "system/bin/boringssl_self_test32" \
        0 2000 755 "u:object_r:boringssl_self_test_exec:s0"

    # Correct the old HAL-only bootstrap labels as well as the new files.
    local FILE
    for FILE in "$WORK_DIR/system/system/lib/bootstrap" "$WORK_DIR/system/system/lib/bootstrap/"*; do
        local MODE=644
        [ -d "$FILE" ] && MODE=755
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
