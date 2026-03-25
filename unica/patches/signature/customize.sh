APPLY_PATCH "system" "system/framework/services.jar" "$MODPATH/0001-Allow-custom-platform-signature.patch"

CERT_SIGNATURE="$(GET_PLATFORM_CERT_SIGNATURE_HEX)" || exit 1

sed -i "s|PUT SIGNATURE HERE|$CERT_SIGNATURE|g" "$APKTOOL_DIR/system/framework/services.jar/smali_classes2/com/android/server/pm/InstallPackageHelper.smali"
