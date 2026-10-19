SKIPUNZIP=1

WALLPAPER_RES_APK="system/priv-app/wallpaper-res/wallpaper-res.apk"
WALLPAPER_RES_APK_PATH="$WORK_DIR/system/$WALLPAPER_RES_APK"
WALLPAPER_RES_SIGNED_APK="$TMP_DIR/wallpaper-res.apk"
WALLPAPER_RES_SOURCE="$MODPATH"

case "$TARGET_CODENAME" in
    r8s) WALLPAPER_RES_SOURCE="$MODPATH/devices/r8s" ;;
    x1s|y2s) WALLPAPER_RES_SOURCE="$MODPATH/devices/x1s_y2s" ;;
    z3s) WALLPAPER_RES_SOURCE="$MODPATH/devices/z3s" ;;
    c1s) WALLPAPER_RES_SOURCE="$MODPATH/devices/c1s" ;;
    c2s) WALLPAPER_RES_SOURCE="$MODPATH/devices/c2s" ;;
esac

# ADD_TO_WORK_DIR rejoins .apk.00, .apk.01, ... before installing the APK.
# Declare parent metadata explicitly, including when adding to a fresh work dir.
for WALLPAPER_RES_DIR in system system/priv-app system/priv-app/wallpaper-res; do
    SET_METADATA "system" "$WALLPAPER_RES_DIR" 0 0 755 "u:object_r:system_file:s0"
done
ADD_TO_WORK_DIR "$WALLPAPER_RES_SOURCE" "system" "$WALLPAPER_RES_APK" 0 0 644 "u:object_r:system_file:s0" || exit 1
SET_METADATA "system" "$WALLPAPER_RES_APK" 0 0 644 "u:object_r:system_file:s0"

[ -n "$APKTOOL_DIR" ] && rm -rf "$APKTOOL_DIR/system/priv-app/wallpaper-res/wallpaper-res.apk"

if [ ! -f "$WALLPAPER_RES_APK_PATH" ]; then
    LOGE "File not found: ${WALLPAPER_RES_APK_PATH//$WORK_DIR/}"
    exit 1
fi

ENSURE_SHARED_PLATFORM_SIGNING_CERTS || exit 1
LOG "- Signing ${WALLPAPER_RES_APK_PATH//$WORK_DIR/}"
if ! command -v signapk > /dev/null; then
    LOGE "signapk not found in PATH"
    exit 1
fi
mkdir -p "$(dirname "$WALLPAPER_RES_SIGNED_APK")"
signapk "$(GET_PLATFORM_CERT_X509_PATH)" "$(GET_PLATFORM_CERT_PK8_PATH)" "$WALLPAPER_RES_APK_PATH" "$WALLPAPER_RES_SIGNED_APK" || exit 1
mv -f "$WALLPAPER_RES_SIGNED_APK" "$WALLPAPER_RES_APK_PATH"
chmod 644 "$WALLPAPER_RES_APK_PATH"

unset WALLPAPER_RES_APK WALLPAPER_RES_APK_PATH WALLPAPER_RES_SIGNED_APK WALLPAPER_RES_SOURCE WALLPAPER_RES_DIR
