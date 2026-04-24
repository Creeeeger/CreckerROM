WALLPAPER_RES_APK="system/priv-app/wallpaper-res/wallpaper-res.apk"
WALLPAPER_RES_APK_PATH="$WORK_DIR/system/$WALLPAPER_RES_APK"
WALLPAPER_RES_SIGNED_APK="$TMP_DIR/wallpaper-res.apk"

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

unset WALLPAPER_RES_APK WALLPAPER_RES_APK_PATH WALLPAPER_RES_SIGNED_APK
