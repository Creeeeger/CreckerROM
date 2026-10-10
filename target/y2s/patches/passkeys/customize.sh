#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

SKIPUNZIP=1

# Keep the donor provisioning API while using the target's SKPM HIDL service.
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" "system/lib64/libsec_skpmTlc.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/libsec_skpmHal.so" 0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/vendor.samsung.hardware.security.skpm@1.0.so" 0 0 644 "u:object_r:system_lib_file:s0"
python3 "$SRC_DIR/scripts/samsung_signing/adapt_skpm_hidl_transport.py" \
    --input "$WORK_DIR/system/system/lib64/libsec_skpmTlc.so" \
    --output "$WORK_DIR/system/system/lib64/libsec_skpmTlc.so" \
    --stock-client "$WORK_DIR/system/system/lib64/libsec_skpmHal.so" \
    --stock-interface "$WORK_DIR/system/system/lib64/vendor.samsung.hardware.security.skpm@1.0.so" || exit 1

# Translate the donor TA ABI against the exact stock secure libraries.
# The root_task property adapter is applied by the Samsung bootchain workflow.
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" "tee/00000000-0000-0000-0000-4662436b6d52" 0 2000 644 "u:object_r:tee_file:s0"
PASSKEY_STOCK_MODEL="${TARGET_FIRMWARE%%/*}"
PASSKEY_STOCK_CSC="${TARGET_FIRMWARE#*/}"
PASSKEY_STOCK_CSC="${PASSKEY_STOCK_CSC%%/*}"
python3 "$SRC_DIR/scripts/samsung_signing/adapt_fkeymaster_stock_abi.py" \
    --input "$WORK_DIR/vendor/tee/00000000-0000-0000-0000-4662436b6d52" \
    --output "$WORK_DIR/vendor/tee/00000000-0000-0000-0000-4662436b6d52" \
    --stock-tzar "$FW_DIR/${PASSKEY_STOCK_MODEL}_${PASSKEY_STOCK_CSC}/bootloader/tzar.img" || exit 1
unset PASSKEY_STOCK_MODEL PASSKEY_STOCK_CSC
