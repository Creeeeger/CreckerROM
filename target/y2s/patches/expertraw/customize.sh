#!/usr/bin/env bash
# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

if [ "$TARGET_CODENAME" != "y2s" ] || [ "$SOURCE_API_LEVEL" != "35" ]; then
    LOGE "The Expert RAW port requires y2s with the Android 15 system image"
    exit 1
fi

ENSURE_SHARED_PLATFORM_SIGNING_CERTS || exit 1

EXPERTRAW_STAGE="$OUT_DIR/expertraw/y2s/module"
mkdir -p "$EXPERTRAW_STAGE/system/priv-app/ExpertRAW" "$EXPERTRAW_STAGE/system/etc/permissions"
python3 "$SRC_DIR/scripts/expertraw/build.py" \
    --tools "$TOOLS_DIR" \
    --cache "$OUT_DIR/downloads/expertraw" \
    --cert "$(GET_PLATFORM_CERT_X509_PATH)" \
    --key "$(GET_PLATFORM_CERT_PK8_PATH)" \
    --profile "$MODPATH/profile.json" \
    --output "$EXPERTRAW_STAGE/system/priv-app/ExpertRAW/ExpertRAW.apk" || exit 1
mv "$EXPERTRAW_STAGE/system/priv-app/ExpertRAW/ExpertRAW.json" "$OUT_DIR/expertraw/y2s/ExpertRAW.json" || exit 1
cp "$MODPATH/privapp-permissions-expertraw.xml" "$EXPERTRAW_STAGE/system/etc/permissions/"

cat > "$EXPERTRAW_STAGE/fs_config-system" <<'EOF'
system 0 0 755 capabilities=0x0
system/priv-app 0 0 755 capabilities=0x0
system/priv-app/ExpertRAW 0 0 755 capabilities=0x0
system/priv-app/ExpertRAW/ExpertRAW.apk 0 0 644 capabilities=0x0
system/etc 0 0 755 capabilities=0x0
system/etc/permissions 0 0 755 capabilities=0x0
system/etc/permissions/privapp-permissions-expertraw.xml 0 0 644 capabilities=0x0
EOF
cat > "$EXPERTRAW_STAGE/file_context-system" <<'EOF'
/system u:object_r:system_file:s0
/system/priv-app u:object_r:system_file:s0
/system/priv-app/ExpertRAW u:object_r:system_file:s0
/system/priv-app/ExpertRAW/ExpertRAW\.apk u:object_r:system_file:s0
/system/etc u:object_r:system_file:s0
/system/etc/permissions u:object_r:system_file:s0
/system/etc/permissions/privapp-permissions-expertraw\.xml u:object_r:system_file:s0
EOF

# Remove metadata accidentally installed by an earlier development build.
if [ -f "$WORK_DIR/system/system/priv-app/ExpertRAW/ExpertRAW.json" ]; then
    DELETE_FROM_WORK_DIR system "system/priv-app/ExpertRAW/ExpertRAW.json" || exit 1
fi

# Install a single privileged copy with the ROM signing identity.
ADD_TO_WORK_DIR "$EXPERTRAW_STAGE" system "system/priv-app/ExpertRAW" 0 0 755 "u:object_r:system_file:s0" || exit 1
SET_METADATA system "system/priv-app/ExpertRAW" 0 0 755 "u:object_r:system_file:s0" || exit 1
SET_METADATA system "system/priv-app/ExpertRAW/ExpertRAW.apk" 0 0 644 "u:object_r:system_file:s0" || exit 1
ADD_TO_WORK_DIR "$EXPERTRAW_STAGE" system "system/etc/permissions/privapp-permissions-expertraw.xml" \
    0 0 644 "u:object_r:system_file:s0" || exit 1
SET_METADATA system "system/etc/permissions/privapp-permissions-expertraw.xml" \
    0 0 644 "u:object_r:system_file:s0" || exit 1

unset EXPERTRAW_STAGE
