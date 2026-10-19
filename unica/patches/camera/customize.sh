if $SOURCE_HAS_MASS_CAMERA_APP; then
    if ! $TARGET_HAS_MASS_CAMERA_APP; then
        ADD_TO_WORK_DIR "e2sxxx" "system" "system/priv-app/SamsungCamera/SamsungCamera.apk" 0 0 644 "u:object_r:system_file:s0"
        ADD_TO_WORK_DIR "e2sxxx" "system" "system/priv-app/SamsungCamera/oat"
    else
        LOG "- TARGET_HAS_MASS_CAMERA_APP is set. Ignoring."
    fi
else
    LOG "- SOURCE_HAS_MASS_CAMERA_APP is not set. Ignoring."
fi

# Legacy scene detection/OCR backport by HackMeGG, adapted from UN1CA:
# https://github.com/salvogiangri/UN1CA/commit/ec9e5c1abda401d32d72e962ae6d2fd0d5abf31a
# TARGET_API_LEVEL describes the target vendor platform, not its launch API.
if [ "$TARGET_API_LEVEL" -lt 34 ]; then
    if $TARGET_HAS_MASS_CAMERA_APP; then
        APPLY_PATCH "system" "system/priv-app/SamsungCamera/SamsungCamera.apk" \
            "$MODPATH/legacy/camera_mass/SamsungCamera.apk/0001-Backport-legacy-Scene-detection-code.patch"
    else
        APPLY_PATCH "system" "system/priv-app/SamsungCamera/SamsungCamera.apk" \
            "$MODPATH/legacy/camera/SamsungCamera.apk/0001-Backport-legacy-Scene-detection-code.patch"
    fi
fi

PATCH_EXYNOS990_100X_ZOOM()
{
    local FILE="$1"
    local HEX
    local FROM
    local TO="f4010000a0860100f4010000a0860100"
    local PATCHED=false

    if [ ! -f "$FILE" ]; then
        LOGE "File not found: ${FILE//$WORK_DIR/}"
        return 1
    fi

    HEX="$(xxd -p "$FILE" | tr -d "\n" | tr -d " ")"

    # Samsung's table is: photo min/max, then video min/max. Accept stock
    # 30x/50x tables (including the N986B 50x/20x variant) and workdirs where
    # the photo-only 100x patch ran already.
    for FROM in \
        "f401000030750000f4010000e02e0000" \
        "f401000050c30000f4010000e02e0000" \
        "f401000050c30000f4010000204e0000" \
        "f4010000a0860100f4010000e02e0000"
    do
        if [[ "$HEX" == *"$FROM"* ]]; then
            HEX="${HEX//$FROM/$TO}"
            PATCHED=true
        fi
    done

    if $PATCHED; then
        LOG "- Enabling 100x photo and video zoom in ${FILE//$WORK_DIR/}"
        printf "%s" "$HEX" | xxd -r -p > "$FILE.tmp"
        mv "$FILE.tmp" "$FILE"
    elif [[ "$HEX" == *"$TO"* ]]; then
        LOGW "100x photo and video zoom already enabled in ${FILE//$WORK_DIR/}"
    else
        LOGE "No supported Exynos990 zoom table match in ${FILE//$WORK_DIR/}"
        return 1
    fi
}

case "$TARGET_CODENAME" in
    x1s|y2s|c1s|c2s|r8s)
        PATCH_EXYNOS990_100X_ZOOM "$WORK_DIR/vendor/lib64/libexynoscamera3.so"
        PATCH_EXYNOS990_100X_ZOOM "$WORK_DIR/vendor/lib/libexynoscamera3.so"
        ;;
esac
