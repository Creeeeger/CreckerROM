PREPARE_ODIN_EXTRA_FIRMWARE_IMAGES()
{
    [ -d "$ODIN_EXTRA_DIR" ] && rm -rf "$ODIN_EXTRA_DIR"
    mkdir -p "$ODIN_EXTRA_AP_DIR" "$ODIN_EXTRA_CP_DIR" "$ODIN_EXTRA_CSC_DIR"

    PREPARE_ODIN_COMPONENT "AP" "dqmdbg.img" "$ODIN_EXTRA_AP_DIR/dqmdbg.img" "download" "" "true"
    PREPARE_ODIN_COMPONENT "AP" "misc.bin" "$ODIN_EXTRA_AP_DIR/misc.bin" "stage2" "misc" "true"

    PREPARE_ODIN_COMPONENT "CSC" "cache.img" "$ODIN_EXTRA_CSC_DIR/cache.img" "download" "" "true"
    PREPARE_ODIN_COMPONENT "CSC" "omr.img" "$ODIN_EXTRA_CSC_DIR/omr.img" "download" "" "true"
}

RUN_SAMSUNG_BOOTLOADER_SIGNING()
{
    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_SIGN_BOOTLOADER || return 0

    "$SRC_DIR/scripts/internal/sign_samsung_bootchain.sh" || exit 1
}

BUILD_ODIN_BL_PACKAGE()
{
    local BL_DIR="$TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR"
    local BL_TAR_PATH="$OUT_DIR/BL_${PACKAGE_NAME}.tar"
    local BL_TAR_MD5="$OUT_DIR/BL_${PACKAGE_NAME}.tar.md5"
    local BL_CHECKSUM
    local -a BL_ARCHIVE_ENTRIES=()

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE || return 0

    if [ ! -d "$BL_DIR" ]; then
        LOGW "Signed bootloader directory does not exist; skipping Odin BL package: $BL_DIR"
        return 0
    fi

    rm -f "$BL_TAR_PATH" "$BL_TAR_MD5"
    pushd "$BL_DIR" > /dev/null
    shopt -s dotglob nullglob
    BL_ARCHIVE_ENTRIES=(*.bin *.img)
    shopt -u dotglob nullglob
    [ "${#BL_ARCHIVE_ENTRIES[@]}" -ge 1 ] || {
        LOGE "No Odin BL package contents were generated"
        exit 1
    }
    tar -cf "$BL_TAR_PATH" -- "${BL_ARCHIVE_ENTRIES[@]}" || exit 1
    popd > /dev/null

    pushd "$OUT_DIR" > /dev/null
    BL_CHECKSUM="$(md5sum -t "$(basename "$BL_TAR_PATH")" | awk '{print $1}')" || exit 1
    printf "%s  %s\n" "$BL_CHECKSUM" "$(basename "$BL_TAR_PATH")" >> "$(basename "$BL_TAR_PATH")"
    mv -f "$(basename "$BL_TAR_PATH")" "$(basename "$BL_TAR_MD5")"
    popd > /dev/null
}

BUILD_ODIN_PACKAGE_FROM_DIR()
{
    local PACKAGE_PREFIX="$1"
    local PACKAGE_DIR="$2"
    local TAR_PATH="$OUT_DIR/${PACKAGE_PREFIX}_${PACKAGE_NAME}.tar"
    local TAR_MD5="$OUT_DIR/${PACKAGE_PREFIX}_${PACKAGE_NAME}.tar.md5"
    local CHECKSUM
    local -a ARCHIVE_ENTRIES=()

    [ -d "$PACKAGE_DIR" ] || {
        LOGW "Odin $PACKAGE_PREFIX package directory does not exist; skipping"
        return 0
    }

    pushd "$PACKAGE_DIR" > /dev/null
    shopt -s dotglob nullglob
    ARCHIVE_ENTRIES=(*)
    shopt -u dotglob nullglob
    if [ "${#ARCHIVE_ENTRIES[@]}" -lt 1 ]; then
        LOGW "No Odin $PACKAGE_PREFIX package contents were generated; skipping"
        popd > /dev/null
        return 0
    fi

    rm -f "$TAR_PATH" "$TAR_MD5"
    tar -cf "$TAR_PATH" -- "${ARCHIVE_ENTRIES[@]}" || exit 1
    popd > /dev/null

    pushd "$OUT_DIR" > /dev/null
    CHECKSUM="$(md5sum -t "$(basename "$TAR_PATH")" | awk '{print $1}')" || exit 1
    printf "%s  %s\n" "$CHECKSUM" "$(basename "$TAR_PATH")" >> "$(basename "$TAR_PATH")"
    mv -f "$(basename "$TAR_PATH")" "$(basename "$TAR_MD5")"
    popd > /dev/null
}

PREPARE_ODIN_AP_DIR()
{
    local PARTITION
    local COMPONENT_FILE
    local STATIC_PARTITIONS="boot dtbo init_boot vendor_boot vbmeta vbmeta_samsung prism optics recovery"
    local IMAGE_DIR="$TMP_DIR"
    local -A AP_INCLUDED_FILES=()
    local -A AP_INCLUDED_PARTITIONS=()
    local EXTRA_FILE

    # Track both partition names and archive filenames; signed image packs and
    # extra firmware sources can refer to the same payload by different names.
    if $TARGET_ENABLE_CUSTOM_AVB; then
        IMAGE_DIR="$TARGET_AVB_IMAGE_PACK_DIR"
    fi

    [ -d "$ODIN_AP_DIR" ] && rm -rf "$ODIN_AP_DIR"
    mkdir -p "$ODIN_AP_DIR"

    if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ] && $TARGET_ODIN_USE_SUPER_IMAGE; then
        LOG "- Building super.img for Odin"
        BUILD_ODIN_SUPER_IMAGE "$ODIN_AP_DIR/super.img" "$IMAGE_DIR"
        AP_INCLUDED_FILES["super.img"]=1
    else
        while IFS= read -r f; do
            PARTITION="$(basename "$f")"
            IS_VALID_PARTITION_NAME "$PARTITION" || continue
            [ -f "$IMAGE_DIR/$PARTITION.img" ] || continue
            cp -fa "$IMAGE_DIR/$PARTITION.img" "$ODIN_AP_DIR/$PARTITION.img"
            AP_INCLUDED_FILES["$PARTITION.img"]=1
            AP_INCLUDED_PARTITIONS["$PARTITION"]=1
        done < <(find "$WORK_DIR" -maxdepth 1 -type d)
    fi

    for PARTITION in $STATIC_PARTITIONS; do
        [ -f "$IMAGE_DIR/$PARTITION.img" ] || continue
        cp -fa "$IMAGE_DIR/$PARTITION.img" "$ODIN_AP_DIR/$PARTITION.img"
        AP_INCLUDED_FILES["$PARTITION.img"]=1
        AP_INCLUDED_PARTITIONS["$PARTITION"]=1
    done

    while IFS= read -r ENTRY; do
        [ -n "$ENTRY" ] || continue
        PARTITION="${ENTRY%%=*}"
        COMPONENT_FILE="${ENTRY#*=}"
        if [ "$PARTITION" = "bootloader" ]; then
            LOGW "Skipping bootloader from AVB firmware components during Odin packaging"
            continue
        fi
        if IS_BOOTLOADER_COMPONENT "$PARTITION" "$COMPONENT_FILE" && ! SHOULD_PACKAGE_BOOTLOADER_COMPONENTS_IN_AP; then
            LOGW "Skipping bootloader component already packaged in BL Odin: $COMPONENT_FILE"
            continue
        fi
        [ -f "$IMAGE_DIR/$COMPONENT_FILE" ] || continue
        if [ -n "${AP_INCLUDED_PARTITIONS[$PARTITION]+x}" ]; then
            LOGW "Skipping duplicate Odin firmware partition $PARTITION ($COMPONENT_FILE)"
            continue
        fi
        if [ -n "${AP_INCLUDED_FILES[$COMPONENT_FILE]+x}" ]; then
            LOGW "Skipping duplicate Odin firmware file $COMPONENT_FILE"
            continue
        fi

        LOG "- Copying Odin firmware component $COMPONENT_FILE"
        cp -fa "$IMAGE_DIR/$COMPONENT_FILE" "$ODIN_AP_DIR/$COMPONENT_FILE"
        AP_INCLUDED_FILES["$COMPONENT_FILE"]=1
        AP_INCLUDED_PARTITIONS["$PARTITION"]=1
    done < <(LIST_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS)

    for PARTITION in $TARGET_ODIN_EXTRA_PARTITIONS; do
        if [ "$PARTITION" = "bootloader" ]; then
            LOGW "Skipping bootloader in TARGET_ODIN_EXTRA_PARTITIONS"
            continue
        fi

        COMPONENT_FILE="$(GET_KV_VALUE "$PARTITION" "$TARGET_ODIN_EXTRA_IMAGE_MAP")"
        [ -n "$COMPONENT_FILE" ] || COMPONENT_FILE="$PARTITION.img"
        if IS_BOOTLOADER_COMPONENT "$PARTITION" "$COMPONENT_FILE" && ! SHOULD_PACKAGE_BOOTLOADER_COMPONENTS_IN_AP; then
            LOGW "Skipping bootloader component already packaged in BL Odin: $COMPONENT_FILE"
            continue
        fi
        [ -f "$IMAGE_DIR/$COMPONENT_FILE" ] || continue
        if [ -n "${AP_INCLUDED_PARTITIONS[$PARTITION]+x}" ]; then
            LOGW "Skipping duplicate Odin firmware partition $PARTITION ($COMPONENT_FILE)"
            continue
        fi
        if [ -n "${AP_INCLUDED_FILES[$COMPONENT_FILE]+x}" ]; then
            LOGW "Skipping duplicate Odin firmware file $COMPONENT_FILE"
            continue
        fi

        LOG "- Copying Odin firmware component $COMPONENT_FILE"
        cp -fa "$IMAGE_DIR/$COMPONENT_FILE" "$ODIN_AP_DIR/$COMPONENT_FILE"
        AP_INCLUDED_FILES["$COMPONENT_FILE"]=1
        AP_INCLUDED_PARTITIONS["$PARTITION"]=1
    done

    if [ -f "$TMP_DIR/up_param.bin" ]; then
        if ! SHOULD_PACKAGE_BOOTLOADER_COMPONENTS_IN_AP; then
            LOGW "Skipping bootloader component already packaged in BL Odin: up_param.bin"
        elif [ -z "${AP_INCLUDED_FILES["up_param.bin"]+x}" ]; then
            cp -fa "$TMP_DIR/up_param.bin" "$ODIN_AP_DIR/up_param.bin"
            AP_INCLUDED_FILES["up_param.bin"]=1
            AP_INCLUDED_PARTITIONS["up_param"]=1
        fi
    fi

    if [ -d "$ODIN_EXTRA_AP_DIR" ]; then
        while IFS= read -r EXTRA_FILE; do
            COMPONENT_FILE="$(basename "$EXTRA_FILE")"
            PARTITION="${COMPONENT_FILE%.*}"
            if [ -n "${AP_INCLUDED_PARTITIONS[$PARTITION]+x}" ]; then
                LOGW "Skipping duplicate Odin AP firmware partition $PARTITION ($COMPONENT_FILE)"
                continue
            fi
            if [ -n "${AP_INCLUDED_FILES[$COMPONENT_FILE]+x}" ]; then
                LOGW "Skipping duplicate Odin AP firmware file $COMPONENT_FILE"
                continue
            fi

            LOG "- Copying Odin AP firmware component $COMPONENT_FILE"
            cp -fa "$EXTRA_FILE" "$ODIN_AP_DIR/$COMPONENT_FILE"
            AP_INCLUDED_FILES["$COMPONENT_FILE"]=1
            AP_INCLUDED_PARTITIONS["$PARTITION"]=1
        done < <(find "$ODIN_EXTRA_AP_DIR" -maxdepth 1 -type f | sort)
    fi

    find "$ODIN_AP_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q . || {
        LOGE "No Odin AP package contents were generated"
        exit 1
    }
}

BUILD_ODIN_AP_PACKAGE()
{
    PREPARE_ODIN_AP_DIR
    BUILD_ODIN_PACKAGE_FROM_DIR "AP" "$ODIN_AP_DIR"
}

BUILD_ODIN_CP_PACKAGE()
{
    $TARGET_BUILD_ODIN_CP_PACKAGE || return 0

    BUILD_ODIN_PACKAGE_FROM_DIR "CP" "$ODIN_EXTRA_CP_DIR"
}

BUILD_ODIN_CSC_PACKAGE()
{
    $TARGET_BUILD_ODIN_CSC_PACKAGE || return 0

    BUILD_ODIN_PACKAGE_FROM_DIR "CSC" "$ODIN_EXTRA_CSC_DIR"
}
