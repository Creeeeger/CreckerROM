GENERATE_BUILD_INFO()
{
    local BUILD_INFO_FILE="$TMP_DIR/build_info.txt"

    {
        echo "device=$TARGET_CODENAME"
        echo "version=$ROM_VERSION"
        echo "timestamp=$ROM_BUILD_TIMESTAMP"
        echo "security_patch_version=$(GET_PROP "system" "ro.build.version.security_patch")"
    } > "$BUILD_INFO_FILE"
}

# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/common.py#4042
GENERATE_OP_LIST()
{
    local OP_LIST_FILE="$TMP_DIR/dynamic_partitions_op_list"

    local HAS_SYSTEM=false
    local HAS_VENDOR=false
    local HAS_PRODUCT=false
    local HAS_SYSTEM_EXT=false
    local HAS_ODM=false
    local HAS_VENDOR_DLKM=false
    local HAS_ODM_DLKM=false
    local HAS_SYSTEM_DLKM=false

    [ -f "$TMP_DIR/system.img" ] && HAS_SYSTEM=true
    [ -f "$TMP_DIR/vendor.img" ] && HAS_VENDOR=true
    [ -f "$TMP_DIR/product.img" ] && HAS_PRODUCT=true
    [ -f "$TMP_DIR/system_ext.img" ] && HAS_SYSTEM_EXT=true
    [ -f "$TMP_DIR/odm.img" ] && HAS_ODM=true
    [ -f "$TMP_DIR/vendor_dlkm.img" ] && HAS_VENDOR_DLKM=true
    [ -f "$TMP_DIR/odm_dlkm.img" ] && HAS_ODM_DLKM=true
    [ -f "$TMP_DIR/system_dlkm.img" ] && HAS_SYSTEM_DLKM=true

    local PARTITION_SIZE=0
    local OCCUPIED_SPACE=0

    # Recovery applies this list before block_image_update, so emit a complete
    # full-OTA layout from the image files present in TMP_DIR.
    {
        echo "# Remove all existing dynamic partitions and groups before applying full OTA"
        echo "remove_all_groups"
        echo "# Add group $TARGET_SUPER_GROUP_NAME with maximum size $TARGET_SUPER_GROUP_SIZE"
        echo "add_group $TARGET_SUPER_GROUP_NAME $TARGET_SUPER_GROUP_SIZE"
        $HAS_SYSTEM && echo "# Add partition system to group $TARGET_SUPER_GROUP_NAME"
        $HAS_SYSTEM && echo "add system $TARGET_SUPER_GROUP_NAME"
        $HAS_VENDOR && echo "# Add partition vendor to group $TARGET_SUPER_GROUP_NAME"
        $HAS_VENDOR && echo "add vendor $TARGET_SUPER_GROUP_NAME"
        $HAS_PRODUCT && echo "# Add partition product to group $TARGET_SUPER_GROUP_NAME"
        $HAS_PRODUCT && echo "add product $TARGET_SUPER_GROUP_NAME"
        $HAS_SYSTEM_EXT && echo "# Add partition system_ext to group $TARGET_SUPER_GROUP_NAME"
        $HAS_SYSTEM_EXT && echo "add system_ext $TARGET_SUPER_GROUP_NAME"
        $HAS_ODM && echo "# Add partition odm to group $TARGET_SUPER_GROUP_NAME"
        $HAS_ODM && echo "add odm $TARGET_SUPER_GROUP_NAME"
        $HAS_VENDOR_DLKM && echo "# Add partition vendor_dlkm to group $TARGET_SUPER_GROUP_NAME"
        $HAS_VENDOR_DLKM && echo "add vendor_dlkm $TARGET_SUPER_GROUP_NAME"
        $HAS_ODM_DLKM && echo "# Add partition odm_dlkm to group $TARGET_SUPER_GROUP_NAME"
        $HAS_ODM_DLKM && echo "add odm_dlkm $TARGET_SUPER_GROUP_NAME"
        $HAS_SYSTEM_DLKM && echo "# Add partition system_dlkm to group $TARGET_SUPER_GROUP_NAME"
        $HAS_SYSTEM_DLKM && echo "add system_dlkm $TARGET_SUPER_GROUP_NAME"
        if $HAS_SYSTEM; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/system.img")"
            echo "# Grow partition system from 0 to $PARTITION_SIZE"
            echo "resize system $PARTITION_SIZE"
            OCCUPIED_SPACE=$((OCCUPIED_SPACE + PARTITION_SIZE))
        fi
        if $HAS_VENDOR; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/vendor.img")"
            echo "# Grow partition vendor from 0 to $PARTITION_SIZE"
            echo "resize vendor $PARTITION_SIZE"
            OCCUPIED_SPACE=$((OCCUPIED_SPACE + PARTITION_SIZE))
        fi
        if $HAS_PRODUCT; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/product.img")"
            echo "# Grow partition product from 0 to $PARTITION_SIZE"
            echo "resize product $PARTITION_SIZE"
            OCCUPIED_SPACE=$((OCCUPIED_SPACE + PARTITION_SIZE))
        fi
        if $HAS_SYSTEM_EXT; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/system_ext.img")"
            echo "# Grow partition system_ext from 0 to $PARTITION_SIZE"
            echo "resize system_ext $PARTITION_SIZE"
            OCCUPIED_SPACE=$((OCCUPIED_SPACE + PARTITION_SIZE))
        fi
        if $HAS_ODM; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/odm.img")"
            echo "# Grow partition odm from 0 to $PARTITION_SIZE"
            echo "resize odm $PARTITION_SIZE"
            OCCUPIED_SPACE=$((OCCUPIED_SPACE + PARTITION_SIZE))
        fi
        if $HAS_VENDOR_DLKM; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/vendor_dlkm.img")"
            echo "# Grow partition vendor_dlkm from 0 to $PARTITION_SIZE"
            echo "resize vendor_dlkm $PARTITION_SIZE"
            OCCUPIED_SPACE=$((OCCUPIED_SPACE + PARTITION_SIZE))
        fi
        if $HAS_ODM_DLKM; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/odm_dlkm.img")"
            echo "# Grow partition odm_dlkm from 0 to $PARTITION_SIZE"
            echo "resize odm_dlkm $PARTITION_SIZE"
            OCCUPIED_SPACE=$((OCCUPIED_SPACE + PARTITION_SIZE))
        fi
        if $HAS_SYSTEM_DLKM; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/system_dlkm.img")"
            echo "# Grow partition system_dlkm from 0 to $PARTITION_SIZE"
            echo "resize system_dlkm $PARTITION_SIZE"
            OCCUPIED_SPACE=$((OCCUPIED_SPACE + PARTITION_SIZE))
        fi
    } > "$OP_LIST_FILE"

    if [[ "$OCCUPIED_SPACE" -gt "$TARGET_SUPER_GROUP_SIZE" ]]; then
        LOGE "OS size ($OCCUPIED_SPACE) is bigger than the target group size ($TARGET_SUPER_GROUP_SIZE)"
        exit 1
    fi
}

GENERATE_OTA_METADATA()
{
    local PROTO_FILE="$SRC_DIR/external/android-tools/vendor/build/tools/releasetools/ota_metadata.proto"

    local INCREMENTAL
    local RELEASE
    local SECURITY_PATCH_LEVEL
    local TIMESTAMP

    INCREMENTAL="$(GET_PROP "system" "ro.build.version.incremental")"
    RELEASE="$(GET_PROP "system" "ro.build.version.release")"
    SECURITY_PATCH_LEVEL="$(GET_PROP "system" "ro.build.version.security_patch")"
    TIMESTAMP="$(GET_PROP "system" "ro.build.date.utc")"

    mkdir -p "$TMP_DIR/META-INF/com/android"

    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/ota_utils.py#259
    if [ -f "$PROTO_FILE" ]; then
        local MESSAGE

        MESSAGE+="type: BLOCK"
        MESSAGE+=", precondition: {device: \\\"$TARGET_CODENAME\\\"}"
        MESSAGE+=", postcondition: {device: \\\"$TARGET_CODENAME\\\""
        MESSAGE+=", build: \\\"$SOURCE_FINGERPRINT\\\""
        MESSAGE+=", build_incremental: \\\"$INCREMENTAL\\\""
        MESSAGE+=", timestamp: $TIMESTAMP"
        MESSAGE+=", sdk_level: \\\"$RELEASE\\\""
        MESSAGE+=", security_patch_level: \\\"$SECURITY_PATCH_LEVEL\\\"}"

        EVAL "protoc --encode=build.tools.releasetools.OtaMetadata --proto_path=\"$(dirname "$PROTO_FILE")\" \"$PROTO_FILE\" <<< \"$MESSAGE\" > \"$TMP_DIR/META-INF/com/android/metadata.pb\"" || exit 1
    fi

    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/ota_utils.py#317
    {
        echo "ota-required-cache=0"
        echo "ota-type=BLOCK"
        echo "post-build=$SOURCE_FINGERPRINT"
        echo "post-build-incremental=$INCREMENTAL"
        echo "post-sdk-level=$RELEASE"
        echo "post-security-patch-level=$SECURITY_PATCH_LEVEL"
        echo "post-timestamp=$TIMESTAMP"
        echo "pre-device=$TARGET_CODENAME"
    } > "$TMP_DIR/META-INF/com/android/metadata"
}

GENERATE_UPDATER_SCRIPT()
{
    local SCRIPT_FILE="$TMP_DIR/META-INF/com/google/android/updater-script"
    local BROTLI_EXTENSION=".br"
    local ENTRY=""
    local PARTITION=""
    local COMPONENT_FILE=""

    local PARTITION_COUNT=0
    local HAS_UP_PARAM=false
    local HAS_BOOT=false
    local HAS_DTB=false
    local HAS_DTBO=false
    local HAS_INIT_BOOT=false
    local HAS_VENDOR_BOOT=false
    local HAS_VBMETA=false
    local HAS_SUPER_EMPTY=false
    local HAS_SYSTEM=false
    local HAS_VENDOR=false
    local HAS_PRODUCT=false
    local HAS_SYSTEM_EXT=false
    local HAS_ODM=false
    local HAS_VENDOR_DLKM=false
    local HAS_ODM_DLKM=false
    local HAS_SYSTEM_DLKM=false
    local HAS_PRISM=false
    local HAS_OPTICS=false
    local HAS_POST_INSTALL=false

    [ -f "$TMP_DIR/up_param.bin" ] && HAS_UP_PARAM=true
    [ -f "$TMP_DIR/boot.img" ] && HAS_BOOT=true
    [ -f "$TMP_DIR/dtb.img" ] && HAS_DTB=true
    [ -f "$TMP_DIR/dtbo.img" ] && HAS_DTBO=true
    [ -f "$TMP_DIR/init_boot.img" ] && HAS_INIT_BOOT=true
    [ -f "$TMP_DIR/vendor_boot.img" ] && HAS_VENDOR_BOOT=true
    [ -f "$TMP_DIR/vbmeta.img" ] && $TARGET_ENABLE_CUSTOM_AVB && $TARGET_AVB_FLASH_VBMETA_IN_ZIP && HAS_VBMETA=true
    [ -f "$TMP_DIR/unsparse_super_empty.img" ] && HAS_SUPER_EMPTY=true
    [ -f "$TMP_DIR/system.new.dat${BROTLI_EXTENSION}" ] && HAS_SYSTEM=true
    [ -f "$TMP_DIR/vendor.new.dat${BROTLI_EXTENSION}" ] && HAS_VENDOR=true && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/product.new.dat${BROTLI_EXTENSION}" ] && HAS_PRODUCT=true && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/system_ext.new.dat${BROTLI_EXTENSION}" ] && HAS_SYSTEM_EXT=true && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/odm.new.dat${BROTLI_EXTENSION}" ] && HAS_ODM=true && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/vendor_dlkm.new.dat${BROTLI_EXTENSION}" ] && HAS_VENDOR_DLKM=true && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/odm_dlkm.new.dat${BROTLI_EXTENSION}" ] && HAS_ODM_DLKM=true && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/system_dlkm.new.dat${BROTLI_EXTENSION}" ] && HAS_SYSTEM_DLKM=true && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/prism.new.dat${BROTLI_EXTENSION}" ] && HAS_PRISM=true
    [ -f "$TMP_DIR/optics.new.dat${BROTLI_EXTENSION}" ] && HAS_OPTICS=true
    [ -f "$SRC_DIR/target/$TARGET_CODENAME/postinstall.edify" ] && HAS_POST_INSTALL=true

    # All HAS_* flags are computed up front so the generated edify script only
    # references files that were actually placed in the package.
    {
        if [ -n "$TARGET_ASSERT_MODEL" ]; then
            IFS=':' read -r -a TARGET_ASSERT_MODEL <<< "$TARGET_ASSERT_MODEL"
            for i in "${TARGET_ASSERT_MODEL[@]}"; do
                echo -n 'getprop("ro.boot.em.model") == "'
                echo -n "$i"
                echo -n '" || '
            done
            echo -n 'abort("E3004: This package is for \"'
            echo -n "$TARGET_CODENAME"
            echo    '\" devices; this is a \"" + getprop("ro.product.device") + "\".");'
        else
            echo -n 'getprop("ro.product.device") == "'
            echo -n "$TARGET_CODENAME"
            echo -n '" || abort("E3004: This package is for \"'
            echo -n "$TARGET_CODENAME"
            echo    '\" devices; this is a \"" + getprop("ro.product.device") + "\".");'
        fi
        if $TARGET_REQUIRES_SPECIFIC_FIRMWARE; then
            TARGET_FW_VERSION=$(GET_PROP "$WORK_DIR/vendor/build.prop" ro.vendor.build.version.incremental)
            [[ "$TARGET_SUPPORTED_FIRMWARES" == "none" ]] \
                && TARGET_SUPPORTED_FIRMWARES=("$TARGET_FW_VERSION") \
                || TARGET_SUPPORTED_FIRMWARES+=("$TARGET_FW_VERSION")
            BL=""
            for i in "${TARGET_SUPPORTED_FIRMWARES[@]}"; do
                BL+="getprop(\"ro.bootloader\") == \"$i\" || "
            done
            BL=""${BL% || }""

            echo -e "ifelse($BL,\"\","
            echo -e 'abort("E3004: Your firmware is not supported. Please flash included Odin pack or wait for a new release.'
            echo -e 'Do not open issues on GitHub!"););'
        fi

        PRINT_HEADER

        if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
            # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/common.py#4007
            echo -e "\n# --- Start patching dynamic partitions ---\n\n"
            echo -e "# Update dynamic partition metadata\n"
            echo -n 'assert(update_dynamic_partitions(package_extract_file("dynamic_partitions_op_list")'
            if $HAS_SUPER_EMPTY; then
                # https://github.com/LineageOS/android_build/commit/98549f6893c3a93057e2d4cdd1015a93e9473b16
                # https://github.com/LineageOS/android_bootable_deprecated-ota/commit/e97be4333bd3824b8561c9637e9e6de28bc29da0
                echo -n ', package_extract_file("unsparse_super_empty.img")'
            fi
            echo    '));'
        fi
        echo    'show_progress(1, 200);'
        if $HAS_SYSTEM; then
            echo -e "\n# Patch partition system\n"
            echo    'ui_print("Patching system image unconditionally...");'
            echo -n    'block_image_update('
            if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
                echo -n    'map_partition("system"), '
            else
                echo -n    '"'
                echo -n    "$TARGET_BOOT_DEVICE_PATH"
                echo -n    '/system", '
            fi
            echo -n    'package_extract_file("system.transfer.list"), '
            echo -n    "\"system.new.dat${BROTLI_EXTENSION}\""
            echo       ', "system.patch.dat") ||'
            echo    '  abort("E1001: Failed to update system image.");'
        fi
        if $HAS_VENDOR; then
            echo -e "\n# Patch partition vendor\n"
            echo    'ui_print("Patching vendor image unconditionally...");'
            echo -n    'block_image_update('
            if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
                echo -n    'map_partition("vendor"), '
            else
                echo -n    '"'
                echo -n    "$TARGET_BOOT_DEVICE_PATH"
                echo -n    '/vendor", '
            fi
            echo -n    'package_extract_file("vendor.transfer.list"), '
            echo -n    "\"vendor.new.dat${BROTLI_EXTENSION}\""
            echo       ', "vendor.patch.dat") ||'
            echo    '  abort("E2001: Failed to update vendor image.");'
        fi
        if $HAS_PRODUCT; then
            echo -e "\n# Patch partition product\n"
            echo    'ui_print("Patching product image unconditionally...");'
            echo -n    'block_image_update('
            if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
                echo -n    'map_partition("product"), '
            else
                echo -n    '"'
                echo -n    "$TARGET_BOOT_DEVICE_PATH"
                echo -n    '/product", '
            fi
            echo -n    'package_extract_file("product.transfer.list"), '
            echo -n    "\"product.new.dat${BROTLI_EXTENSION}\""
            echo       ', "product.patch.dat") ||'
            echo    '  abort("E2001: Failed to update product image.");'
        fi
        if $HAS_SYSTEM_EXT; then
            echo -e "\n# Patch partition system_ext\n"
            echo    'ui_print("Patching system_ext image unconditionally...");'
            echo -n    'block_image_update('
            if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
                echo -n    'map_partition("system_ext"), '
            else
                echo -n    '"'
                echo -n    "$TARGET_BOOT_DEVICE_PATH"
                echo -n    '/system_ext", '
            fi
            echo -n    'package_extract_file("system_ext.transfer.list"), '
            echo -n    "\"system_ext.new.dat${BROTLI_EXTENSION}\""
            echo       ', "system_ext.patch.dat") ||'
            echo    '  abort("E2001: Failed to update system_ext image.");'
        fi
        if $HAS_ODM; then
            echo -e "\n# Patch partition odm\n"
            echo    'ui_print("Patching odm image unconditionally...");'
            echo -n    'block_image_update('
            if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
                echo -n    'map_partition("odm"), '
            else
                echo -n    '"'
                echo -n    "$TARGET_BOOT_DEVICE_PATH"
                echo -n    '/odm", '
            fi
            echo -n    'package_extract_file("odm.transfer.list"), '
            echo -n    "\"odm.new.dat${BROTLI_EXTENSION}\""
            echo       ', "odm.patch.dat") ||'
            echo    '  abort("E2001: Failed to update odm image.");'
        fi
        if $HAS_VENDOR_DLKM; then
            echo -e "\n# Patch partition vendor_dlkm\n"
            echo    'ui_print("Patching vendor_dlkm image unconditionally...");'
            echo -n    'block_image_update('
            if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
                echo -n    'map_partition("vendor_dlkm"), '
            else
                echo -n    '"'
                echo -n    "$TARGET_BOOT_DEVICE_PATH"
                echo -n    '/vendor_dlkm", '
            fi
            echo -n    'package_extract_file("vendor_dlkm.transfer.list"), '
            echo -n    "\"vendor_dlkm.new.dat${BROTLI_EXTENSION}\""
            echo       ', "vendor_dlkm.patch.dat") ||'
            echo    '  abort("E2001: Failed to update vendor_dlkm image.");'
        fi
        if $HAS_ODM_DLKM; then
            echo -e "\n# Patch partition odm_dlkm\n"
            echo    'ui_print("Patching odm_dlkm image unconditionally...");'
            echo -n    'block_image_update('
            if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
                echo -n    'map_partition("odm_dlkm"), '
            else
                echo -n    '"'
                echo -n    "$TARGET_BOOT_DEVICE_PATH"
                echo -n    '/odm_dlkm", '
            fi
            echo -n    'package_extract_file("odm_dlkm.transfer.list"), '
            echo -n    "\"odm_dlkm.new.dat${BROTLI_EXTENSION}\""
            echo       ', "odm_dlkm.patch.dat") ||'
            echo    '  abort("E2001: Failed to update odm_dlkm image.");'
        fi
        if $HAS_SYSTEM_DLKM; then
            echo -e "\n# Patch partition system_dlkm\n"
            echo    'ui_print("Patching system_dlkm image unconditionally...");'
            echo -n    'block_image_update('
            if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
                echo -n    'map_partition("system_dlkm"), '
            else
                echo -n    '"'
                echo -n    "$TARGET_BOOT_DEVICE_PATH"
                echo -n    '/system_dlkm", '
            fi
            echo -n    'package_extract_file("system_dlkm.transfer.list"), '
            echo -n    "\"system_dlkm.new.dat${BROTLI_EXTENSION}\""
            echo       ', "system_dlkm.patch.dat") ||'
            echo    '  abort("E2001: Failed to update system_dlkm image.");'
        fi
        if $HAS_PRISM; then
            echo -e "\n# Patch partition prism\n"
            echo    'ui_print("Patching prism image unconditionally...");'
            echo -n    'block_image_update('
            echo -n    '"'
            echo -n    "$TARGET_BOOT_DEVICE_PATH"
            echo -n    '/prism", '
            echo -n    'package_extract_file("prism.transfer.list"), '
            echo -n    "\"prism.new.dat${BROTLI_EXTENSION}\""
            echo       ', "prism.patch.dat") ||'
            echo    '  abort("E2001: Failed to update prism image.");'
        fi
        if $HAS_OPTICS; then
            echo -e "\n# Patch partition optics\n"
            echo    'ui_print("Patching optics image unconditionally...");'
            echo -n    'block_image_update('
            echo -n    '"'
            echo -n    "$TARGET_BOOT_DEVICE_PATH"
            echo -n    '/optics", '
            echo -n    'package_extract_file("optics.transfer.list"), '
            echo -n    "\"optics.new.dat${BROTLI_EXTENSION}\""
            echo       ', "optics.patch.dat") ||'
            echo    '  abort("E2001: Failed to update optics image.");'
        fi
        if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
            echo -e "\n# --- End patching dynamic partitions ---\n"
        else
            echo -e "\n"
        fi
        echo    'set_progress(0);'
        if $HAS_DTB; then
            echo    'ui_print("Full Patching dtb.img img...");'
            echo -n 'package_extract_file("dtb.img", "'
            echo -n "$TARGET_BOOT_DEVICE_PATH"
            echo    '/dtb");'
        fi
        if $HAS_DTBO; then
            echo    'ui_print("Full Patching dtbo.img img...");'
            echo -n 'package_extract_file("dtbo.img", "'
            echo -n "$TARGET_BOOT_DEVICE_PATH"
            echo    '/dtbo");'
        fi
        if $HAS_INIT_BOOT; then
            echo    'ui_print("Full Patching init_boot.img img...");'
            echo -n 'package_extract_file("init_boot.img", "'
            echo -n "$TARGET_BOOT_DEVICE_PATH"
            echo    '/init_boot");'
        fi
        if $HAS_VENDOR_BOOT; then
            echo    'ui_print("Full Patching vendor_boot.img img...");'
            echo -n 'package_extract_file("vendor_boot.img", "'
            echo -n "$TARGET_BOOT_DEVICE_PATH"
            echo    '/vendor_boot");'
        fi
        if $HAS_BOOT; then
            echo    'ui_print("Installing boot image...");'
            echo -n 'package_extract_file("boot.img", "'
            echo -n "$TARGET_BOOT_DEVICE_PATH"
            echo    '/boot");'
        fi
        if $HAS_VBMETA; then
            echo    'ui_print("Installing vbmeta image...");'
            echo -n 'package_extract_file("vbmeta.img", "'
            echo -n "$TARGET_BOOT_DEVICE_PATH"
            echo    '/vbmeta");'
        fi
        if $HAS_UP_PARAM; then
            echo    'ui_print("Installing up_param image...");'
            echo -n 'package_extract_file("up_param.bin", "'
            echo -n "$TARGET_BOOT_DEVICE_PATH"
            echo    '/up_param");'
        fi
        while IFS= read -r ENTRY; do
            [ -n "$ENTRY" ] || continue
            PARTITION="${ENTRY%%=*}"
            COMPONENT_FILE="${ENTRY#*=}"
            [ "$PARTITION" = "bootloader" ] && continue
            [ -f "$TMP_DIR/$COMPONENT_FILE" ] || continue

            # Firmware components listed in avb_manifest.txt are flashed as raw
            # block-device payloads, not through block_image_update.
            echo    "ui_print(\"Installing $PARTITION firmware component...\");"
            echo -n 'package_extract_file("'
            echo -n "$COMPONENT_FILE"
            echo -n '", "'
            echo -n "$TARGET_BOOT_DEVICE_PATH"
            echo -n '/'
            echo -n "$PARTITION"
            echo    '");'
        done < <(LIST_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS)

        if $HAS_POST_INSTALL; then
            echo -e "\n"
            echo    'ui_print("Executing post-install tasks...");'
            cat "$SRC_DIR/target/$TARGET_CODENAME/postinstall.edify"
        fi

        echo -e "\n"
        echo    'ui_print("Cleaning up...");'
        echo    'package_extract_file("cleanup.sh", "/tmp/cleanup.sh");'
        echo    'set_metadata("/tmp/cleanup.sh", "uid", 0, "gid", 0, "dmode", 0755, "fmode", 0755);'
        echo    'run_program("/tmp/cleanup.sh");'

        echo -e "\n"
        echo    'set_progress(1);'
        echo    'ui_print("****************************************************");'
        echo    'ui_print(" ");'
    } > "$SCRIPT_FILE"
}

PRINT_HEADER()
{
    local ONEUI_VERSION
    local MAJOR
    local MINOR
    local PATCH

    ONEUI_VERSION="$(GET_PROP "system" "ro.build.version.oneui")"
    MAJOR=$(bc -l <<< "scale=0; $ONEUI_VERSION / 10000")
    MINOR=$(bc -l <<< "scale=0; $ONEUI_VERSION % 10000 / 100")
    PATCH=$(bc -l <<< "scale=0; $ONEUI_VERSION % 100")
    if [[ "$PATCH" != "0" ]]; then
        ONEUI_VERSION="$MAJOR.$MINOR.$PATCH"
    else
        ONEUI_VERSION="$MAJOR.$MINOR"
    fi

    echo    'ui_print(" ");'
    echo    'ui_print("****************************************************");'
    echo -n 'ui_print("'
    echo -n "Welcome to $ROM_DISPLAY_NAME for $TARGET_NAME!"
    echo    '");'
    echo    'ui_print("****************************************************");'
    echo -n 'ui_print("'
    echo -n "One UI version: $ONEUI_VERSION"
    echo    '");'
    echo -n 'ui_print("'
    echo -n "Source: $SOURCE_FINGERPRINT"
    echo    '");'
    echo -n 'ui_print("'
    echo -n "Target: $TARGET_FINGERPRINT"
    echo    '");'
    echo    'ui_print("****************************************************");'
    echo    'ui_print("After installation, it is highly recommended to FORMAT DATA as follows:");'
    echo    'ui_print("     Wipe -> Format Data");'
    echo    'ui_print("Hint: FORMAT, not WIPE or FACTORY RESET!");'
    echo    'ui_print(" ");'
    echo    'ui_print("If you decide to not format, unexpected issues may occur and given support will be limited.");'
    echo    'ui_print(" ");'
    echo    'ui_print("If you wish to proceed with the installer, please press the Volume UP button.");'
    echo    'ui_print("Otherwise, hold the Volume DOWN + POWER buttons for 7 seconds to force reboot.");'
    echo    'assert(run_program("/sbin/sh", "-c", "while true; do getevent -lc 1 | grep -q -m1 '\''KEY_VOLUMEUP'\'' && exit 0; sleep 1; done"));'
    echo    'ui_print("Volume UP detected. Proceeding!");'
}
