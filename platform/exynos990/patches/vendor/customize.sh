LOG_STEP_IN "- Updating Vibrator/RIL/Face/WPA HALs"
# Delete hermes to get rid of weaver encryption blobs
BLOBS_LIST="
bin/hw/vendor.samsung.hardware.vibrator@2.2-service
etc/init/vendor.samsung.hardware.vibrator@2.2-service.rc
lib64/vendor.samsung.hardware.vibrator@2.0.so
lib64/vendor.samsung.hardware.vibrator@2.1.so
lib64/vendor.samsung.hardware.vibrator@2.2.so
bin/hw/vendor.samsung.hardware.biometrics.face@2.0-service
etc/init/vendor.samsung.hardware.biometrics.face@2.0-service.rc
bin/hermesd
etc/init/hermesd.rc
lib/liboemcrypto.so
"
for blob in $BLOBS_LIST
do
    DELETE_FROM_WORK_DIR "vendor" "$blob"
done

ADD_TO_WORK_DIR "p3sxxx" "vendor" "bin/hw/vendor.samsung.hardware.biometrics.face@3.0-service"
ADD_TO_WORK_DIR "p3sxxx" "vendor" "bin/hw/vendor.samsung.hardware.vibrator-service"
ADD_TO_WORK_DIR "p3sxxx" "vendor" "lib64"
ADD_TO_WORK_DIR "p3sxxx" "vendor" "etc/init"
ADD_TO_WORK_DIR "p3sxxx" "vendor" "etc/vintf"

# Required by newer source framework components using fabric_crypto.
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" "bin/vendor.samsung.hardware.security.fkeymaster-service"
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" "etc/init/vendor.samsung.hardware.security.fkeymaster-service.rc"
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" "etc/vintf/manifest/vendor.samsung.hardware.security.fkeymaster-service.xml"
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" "lib64/vendor.samsung.hardware.security.fkeymaster-V1-ndk.so"
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" "tee/00000000-0000-0000-0000-4662436b6d52" 0 2000 644 "u:object_r:tee_file:s0"

APPEND_SEPOLICY_RULE()
{
    local rule="$1"

    grep -q -F "$rule" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil" || \
        echo "$rule" >> "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"
}

ADD_TYPEATTRIBUTESET_MEMBER()
{
    local attribute="$1"
    local type="$2"

    if grep -q -F "(typeattributeset $attribute " "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil" && \
        ! grep -q -E "^\\(typeattributeset $attribute .*([[:space:]]|\\()$type([[:space:]]|\\))" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"; then
        sed -i "/^(typeattributeset $attribute /s/))/ $type))/" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"
    fi
}

FKEYMASTER_SEPOLICY_RULES=(
    "(allow fabriccrypto_${TARGET_VNDK_VERSION}_0 hal_fkey_default (binder (call transfer)))"
    "(allow hal_fkey_default fabriccrypto_${TARGET_VNDK_VERSION}_0 (binder (transfer)))"
    "(allow fabriccrypto_${TARGET_VNDK_VERSION}_0 hal_fkey_default (fd (use)))"
    "(allow fabriccrypto_${TARGET_VNDK_VERSION}_0 hal_fkey_service (service_manager (find)))"
)
if grep -q -F "(type hal_fkey_service)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil" && \
    grep -q -F "(type hal_fkey_default)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil" && \
    grep -q -F "(typeattribute fabriccrypto_${TARGET_VNDK_VERSION}_0)" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil"; then
    for rule in "${FKEYMASTER_SEPOLICY_RULES[@]}"; do
        APPEND_SEPOLICY_RULE "$rule"
    done
fi
if grep -q -F "(typeattribute fabriccrypto_${TARGET_VNDK_VERSION}_0)" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil" && \
    grep -q -F "permission_service_${TARGET_VNDK_VERSION}_0" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil"; then
    APPEND_SEPOLICY_RULE "(allow fabriccrypto_${TARGET_VNDK_VERSION}_0 permission_service_${TARGET_VNDK_VERSION}_0 (service_manager (find)))"
fi
if grep -q -F "(typeattribute fabriccrypto_${TARGET_VNDK_VERSION}_0)" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil" && \
    grep -q -F "system_server_${TARGET_VNDK_VERSION}_0" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil"; then
    APPEND_SEPOLICY_RULE "(allow fabriccrypto_${TARGET_VNDK_VERSION}_0 system_server_${TARGET_VNDK_VERSION}_0 (binder (call transfer)))"
    APPEND_SEPOLICY_RULE "(allow system_server_${TARGET_VNDK_VERSION}_0 fabriccrypto_${TARGET_VNDK_VERSION}_0 (binder (transfer)))"
    APPEND_SEPOLICY_RULE "(allow fabriccrypto_${TARGET_VNDK_VERSION}_0 system_server_${TARGET_VNDK_VERSION}_0 (fd (use)))"
fi
FKEYMASTER_TZTS_PROP_RULE="(allow hal_fkey_default vendor_tztsdaemon_prop (file (read getattr map open)))"
if grep -q -F "(type hal_fkey_default)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil" && \
    grep -q -F "(type vendor_tztsdaemon_prop)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"; then
    APPEND_SEPOLICY_RULE "$FKEYMASTER_TZTS_PROP_RULE"
fi
FKEYMASTER_TZDEV_RULE="(allow hal_fkey_default tz_user_device (chr_file (ioctl read write getattr lock append map open watch watch_reads)))"
if grep -q -F "(type hal_fkey_default)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil" && \
    grep -q -F "(type tz_user_device)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"; then
    APPEND_SEPOLICY_RULE "$FKEYMASTER_TZDEV_RULE"
fi
if ! grep -q -F "(type vendor_teegris_prop)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"; then
    echo "(type vendor_teegris_prop)" >> "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"
    echo "(roletype object_r vendor_teegris_prop)" >> "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"
fi
if grep -q -F "(type vendor_teegris_prop)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"; then
    ADD_TYPEATTRIBUTESET_MEMBER "property_type" "vendor_teegris_prop"
    ADD_TYPEATTRIBUTESET_MEMBER "vendor_property_type" "vendor_teegris_prop"
    ADD_TYPEATTRIBUTESET_MEMBER "vendor_public_property_type" "vendor_teegris_prop"
    grep -q -F "vendor.TEEGRIS." "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts" || \
        echo "vendor.TEEGRIS.                             u:object_r:vendor_teegris_prop:s0" >> "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts"
    grep -q -F "vendor.teegris." "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts" || \
        echo "vendor.teegris.                             u:object_r:vendor_teegris_prop:s0" >> "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts"
    if grep -q -F "(type hal_fkey_default)" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"; then
        APPEND_SEPOLICY_RULE "(allow hal_fkey_default vendor_teegris_prop (file (read getattr map open)))"
    fi
    if grep -q -F "vendor_init_${TARGET_VNDK_VERSION}_0" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil"; then
        APPEND_SEPOLICY_RULE "(allow vendor_init_${TARGET_VNDK_VERSION}_0 vendor_teegris_prop (property_service (set)))"
        APPEND_SEPOLICY_RULE "(allow vendor_init_${TARGET_VNDK_VERSION}_0 vendor_teegris_prop (file (read getattr map open)))"
    fi
fi

# WPA Supplicant HAL
if [[ "$TARGET_CODENAME" != "r8s" ]]; then
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "bin/hw/wpa_supplicant"
fi

# Light HAL
if [[ "$TARGET_CODENAME" != "r8s" ]]; then
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "bin/hw/vendor.samsung.hardware.light-service"
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "lib64/android.hardware.light-V1-ndk_platform.so"
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "lib64/vendor.samsung.hardware.light-V1-ndk_platform.so"
else
    ADD_TO_WORK_DIR "a73xqxx" "vendor" "bin/hw/vendor.samsung.hardware.light-service"
    ADD_TO_WORK_DIR "a73xqxx" "vendor" "lib64/android.hardware.light-V1-ndk_platform.so"
    ADD_TO_WORK_DIR "a73xqxx" "vendor" "lib64/vendor.samsung.hardware.light-V1-ndk_platform.so"
fi
LOG_STEP_OUT
