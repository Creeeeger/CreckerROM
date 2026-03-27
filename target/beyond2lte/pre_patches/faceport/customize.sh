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
APPLY_PATCH "system" "system/priv-app/BiometricSetting/BiometricSetting.apk" \
    "$FACEPORT_PATCH_DIR/system/priv-app/BiometricSetting/BiometricSetting.apk/0001-faceport-biometricsetting15.patch"
APPLY_PATCH "system_ext" "priv-app/SystemUI/SystemUI.apk" \
    "$FACEPORT_PATCH_DIR/system_ext/priv-app/SystemUI/SystemUI.apk/0001-faceport-systemui.patch"

# Force the face stack through apktool so the final build re-signs it with the ROM platform cert.
FACEPORT_REBUILD_APKS=(
    "system/priv-app/BioFaceService/BioFaceService.apk"
    "system/priv-app/BiometricSetting/BiometricSetting.apk"
    "system/priv-app/FaceService/FaceService.apk"
    "system/priv-app/smartfaceservice/smartfaceservice.apk"
    "system/priv-app/wallpaper-res/wallpaper-res.apk"
)
for FACEPORT_APK in "${FACEPORT_REBUILD_APKS[@]}"; do
    if [ -f "$WORK_DIR/system/$FACEPORT_APK" ]; then
        QUEUE_FILE_FOR_REBUILD "system" "$FACEPORT_APK" || exit 1
    fi
done
unset FACEPORT_APK FACEPORT_REBUILD_APKS

# Ensure faced has the expected ownership, mode, and SELinux label.
SET_METADATA "system" "system/bin/faced" 0 2000 755 u:object_r:faced_exec:s0
