# A26 VOLD/MDF blobs
ADD_TO_WORK_DIR "a26xxx" "system" "."

# Tab S10 FE android_server blobs
ADD_TO_WORK_DIR "gts10fewifixx" "system" "."

# S25 AIDL ICCC blobs
ADD_TO_WORK_DIR "pa3qzcx" "system" "system/lib64/aidl_comm_iccc_client.so"
ADD_TO_WORK_DIR "pa3qzcx" "system" "system/lib64/vendor.samsung.hardware.tlc.iccc-V3-ndk.so"

# DualDAR
DELETE_FROM_WORK_DIR "system" "system/bin/dualdard"
DELETE_FROM_WORK_DIR "system" "system/etc/init/dualdard.rc"
DELETE_FROM_WORK_DIR "system" "system/lib64/libdualdar.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/aidl_comm_ddar_client.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/vendor.samsung.hardware.tlc.ddar-V1-ndk.so"

# eSE COS
DELETE_FROM_WORK_DIR "system" "system/bin/sem_daemon"
DELETE_FROM_WORK_DIR "system" "system/etc/init/sem_early.rc"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.sem.factoryapp.xml"
DELETE_FROM_WORK_DIR "system" "system/lib64/libsec_sem.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libsec_semAidl.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libsec_semRil.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libsec_semTlc.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libspictrl.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/vendor.samsung.hardware.security.sem-V1-ndk.so"
DELETE_FROM_WORK_DIR "system" "system/priv-app/SEMFactoryApp"

# Weaver
DELETE_FROM_WORK_DIR "system" "system/lib64/libhermes_cred.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/android.hardware.weaver-V2-ndk.so"

# HDM
DELETE_FROM_WORK_DIR "system" "system/priv-app/HdmApk"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.hdmapp.xml"

# WSM
DELETE_FROM_WORK_DIR "system" "system/etc/public.libraries-wsm.samsung.txt"
DELETE_FROM_WORK_DIR "system" "system/lib64/libhal.wsm.samsung.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/vendor.samsung.hardware.security.wsm.service-V1-ndk.so"

# Knox ZeroTrust
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.knox.zt.framework.xml"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KnoxZtFramework"

# Knox Matrix
DELETE_FROM_WORK_DIR "system" "system/bin/fabric_crypto"
DELETE_FROM_WORK_DIR "system" "system/etc/init/fabric_crypto.rc"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/FabricCryptoLib.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.kmxservice.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/vintf/manifest/fabric_crypto_manifest.xml"
DELETE_FROM_WORK_DIR "system" "system/framework/FabricCryptoLib.jar"
DELETE_FROM_WORK_DIR "system" "system/lib64/com.samsung.security.fabric.cryptod-V1-cpp.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/vendor.samsung.hardware.security.fkeymaster-V1-cpp.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/vendor.samsung.hardware.security.fkeymaster-V1-ndk.so"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KmxService"
