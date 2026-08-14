LOG_STEP_IN "- Enabling BSOH in SecSettings"

DECODE_APK "system" "system/priv-app/SecSettings/SecSettings.apk"

FTP="
system/priv-app/SecSettings/SecSettings.apk/smali_classes4/com/samsung/android/settings/deviceinfo/batteryinfo/BatteryRegulatoryPreferenceController.smali
system/priv-app/SecSettings/SecSettings.apk/smali_classes4/com/samsung/android/settings/deviceinfo/batteryinfo/SecBatteryFirstUseDatePreferenceController.smali
system/priv-app/SecSettings/SecSettings.apk/smali_classes4/com/samsung/android/settings/deviceinfo/batteryinfo/SecBatteryInfoFragment.smali
"
for f in $FTP; do
    sed -i "s/SM-A236B/SM-S721B/g" "$APKTOOL_DIR/$f"
done
LOG_STEP_OUT

LOG_STEP_IN "- Adding Play Integrity settings"

# Add new resources/smali files and merge the two XML snippets into the
# decoded One UI 7 SecSettings package. XML snippets use their first line as
# the sed insertion command; values files are inserted before </resources>.
while IFS= read -r f; do
    f="${f//$MODPATH\/SecSettings.apk\//}"
    SRC_FILE="$MODPATH/SecSettings.apk/$f"
    DST_FILE="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/$f"

    if [ ! -f "$DST_FILE" ] || [[ "$f" != *".xml" ]]; then
        LOG "- Adding \"$f\" to /system/system/priv-app/SecSettings.apk"
        mkdir -p "$(dirname "$DST_FILE")"
        cp -a "$SRC_FILE" "$DST_FILE"
    else
        LOG "- Patching \"$f\" in /system/system/priv-app/SecSettings.apk"
        if [[ "$f" == *"res/values"* ]]; then
            while IFS= read -r RESOURCE_NAME; do
                sed -i "/<string name=\"$RESOURCE_NAME\"/d" "$DST_FILE"
            done < <(sed -n 's/.*<string name="\([^"]*\)".*/\1/p' "$SRC_FILE")

            PATCH_INST="/<\/resources>/i"
            CONTENT="$(sed -e "/?xml/d" -e "/resources>/d" "$SRC_FILE")"
        else
            PATCH_INST="$(head -n 1 "$SRC_FILE")"

            if [[ "$PATCH_INST" == "<?xml"* ]]; then
                cp -a "$SRC_FILE" "$DST_FILE"
                continue
            elif [[ "$f" == "res/xml/sec_top_level_settings.xml" ]] && \
                    grep -q 'android:key="top_level_unica_pif"' "$DST_FILE"; then
                continue
            fi

            CONTENT="$(tail -n +2 "$SRC_FILE")"
        fi
        CONTENT="$(sed -e "s/\"/\\\\\"/g" -e "s/\\\$/\\\\\$/g" -e "s/ /\\\\ /g" -e "s/\\\\n/\\\\\\\\\n/g" <<< "$CONTENT")"
        CONTENT="$(sed -E ':a;N;$!ba;s/\r{0,1}\n/\\n/g' <<< "$CONTENT")"
        EVAL "sed -i \"$PATCH_INST $CONTENT\" \"$DST_FILE\""
    fi
done < <(find "$MODPATH/SecSettings.apk" -type f | sort)

unset SRC_FILE DST_FILE RESOURCE_NAME PATCH_INST CONTENT

LOG_STEP_OUT

LOG_STEP_IN "- Adding Multi-User Support"
SET_PROP "system" "fw.max_users" "8"
SET_PROP "system" "fw.show_multiuserui" "1"
LOG_STEP_OUT

LOG_STEP_IN "- Enabling Cached App Freezer"
SET_PROP "system" "persist.device_config.activity_manager_native_boot.use_freezer" "true"
LOG_STEP_OUT

# ro.build.2ndbrand is always "false"
LOG_STEP_IN "- Disabling ASKS"
sed -i "s/ro.build.official.release/ro.build.2ndbrand/g" "$APKTOOL_DIR/system/framework/services.jar/smali/com/android/server/asks/ASKSManagerService.smali"
LOG_STEP_OUT
