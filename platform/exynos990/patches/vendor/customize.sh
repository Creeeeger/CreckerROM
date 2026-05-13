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
        grep -q -F "$rule" "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil" || \
            echo "$rule" >> "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"
    done
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
