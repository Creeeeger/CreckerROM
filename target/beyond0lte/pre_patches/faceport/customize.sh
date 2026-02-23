#!/usr/bin/env bash

FACEPORT_PATCH_DIR="$SRC_DIR/platform/exynos9820/patches/facePort"

# Remove the stock biometric face feature declaration.
if [ -e "$WORK_DIR/system/system/etc/permissions/android.hardware.biometrics.face.xml" ]; then
    DELETE_FROM_WORK_DIR "system" "system/etc/permissions/android.hardware.biometrics.face.xml"
fi
if [ -e "$WORK_DIR/system/system/etc/Permissions/android.hardware.biometrics.face.xml" ]; then
    DELETE_FROM_WORK_DIR "system" "system/etc/Permissions/android.hardware.biometrics.face.xml"
fi
if [ -e "$WORK_DIR/system/system/etc/permissions/android.hardware.biometric.face.xml" ]; then
    DELETE_FROM_WORK_DIR "system" "system/etc/permissions/android.hardware.biometric.face.xml"
fi
if [ -e "$WORK_DIR/system/system/etc/Permissions/android.hardware.biometric.face.xml" ]; then
    DELETE_FROM_WORK_DIR "system" "system/etc/Permissions/android.hardware.biometric.face.xml"
fi

# Apply FacePort patches.
APPLY_PATCH "system" "system/framework/framework.jar" \
    "$FACEPORT_PATCH_DIR/system/framework/framework.jar/0001-faceport-framework.patch"
APPLY_PATCH "system" "system/priv-app/SecSettings/SecSettings.apk" \
    "$FACEPORT_PATCH_DIR/system/priv-app/SecSettings/SecSettings.apk/0001-faceport-secsettings.patch"
APPLY_PATCH "system_ext" "priv-app/SystemUI/SystemUI.apk" \
    "$FACEPORT_PATCH_DIR/system_ext/priv-app/SystemUI/SystemUI.apk/0001-faceport-systemui.patch"

# Ensure faced has the expected ownership, mode, and SELinux label.
SET_METADATA "system" "system/bin/faced" 0 2000 755 u:object_r:faced_exec:s0
