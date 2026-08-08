GET_BUILD_VAR()
{
    local VALUE

    if [ "$#" -ge 2 ]; then
        if [ ! "${!1}" ]; then
            VALUE="$2"
            VALUE="${VALUE//\\/\\\\}"
            VALUE="${VALUE//\"/\\\"}"
            echo "${1}=\"${VALUE}\""
            return 0
        fi
    else
        _CHECK_NON_EMPTY_PARAM "$1" "${!1}" || exit 1
    fi

    VALUE="${!1}"
    VALUE="${VALUE//\\/\\\\}"
    VALUE="${VALUE//\"/\\\"}"
    echo "${1}=\"${VALUE}\""
    return 0
}

GET_DEFAULT_ROM_IS_OFFICIAL()
{
    if [ "${ROM_IS_OFFICIAL:-}" = "true" ] || [ "${ROM_IS_OFFICIAL:-}" = "false" ]; then
        echo "$ROM_IS_OFFICIAL"
    elif [ "${ROM_TYPE:-default}" = "official" ]; then
        echo "true"
    else
        echo "false"
    fi
}

SANITIZE_CONFIG_ENV()
{
    local VAR

    while IFS= read -r VAR; do
        case "$VAR" in
            SOURCE_*|TARGET_*|ROM_VERSION|ROM_CODENAME|ROM_DISPLAY_NAME|ROM_TYPE|ROM_BUILD_TIMESTAMP)
                unset "$VAR"
                ;;
        esac
    done < <(compgen -v)
}

GET_DEFAULT_ODIN_SUPER_IMAGE()
{
    if [ "${TARGET_SUPER_PARTITION_SIZE:-0}" -eq 0 ]; then
        echo "false"
    elif [[ "$TARGET_NAME" == Galaxy\ S20* ]] || [[ "$TARGET_NAME" == Galaxy\ S21* ]]; then
        echo "true"
    else
        echo "false"
    fi
}

GET_DEFAULT_SAMSUNG_LK_PATCH_TABLE()
{
    local MODEL
    local PATCH_ID
    local PATCH_TABLE

    MODEL="${TARGET_SAMSUNG_BL1_MODEL:-}"
    if [ -z "$MODEL" ] || [ "$MODEL" = "none" ]; then
        MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
    fi
    PATCH_ID="${MODEL#SM-}"
    PATCH_ID="$(tr "[:upper:]" "[:lower:]" <<< "$PATCH_ID")"
    case "$PATCH_ID" in
        "g780f"|"g980f"|"g981b"|"g985f"|"g986b"|"g988b"|\
        "n980f"|"n981b"|"n985f"|"n986b")
            ;;
        *)
            if [ "$TARGET_PLATFORM" = "exynos990" ]; then
                LOGE "No Samsung LK patch table for selected BL1 model: ${MODEL:-<empty>}"
                return 1
            fi
            echo "none"
            return 0
            ;;
    esac

    PATCH_TABLE="$SRC_DIR/security/samsung/patches/lk_${PATCH_ID}_selected_patches.tsv"
    if [ ! -f "$PATCH_TABLE" ]; then
        LOGE "Missing Samsung LK patch table: $PATCH_TABLE"
        return 1
    fi
    echo "$PATCH_TABLE"
}

GET_DEFAULT_RECOVERY_IMAGE_PATH()
{
    case "$TARGET_CODENAME" in
        "r8s")
            echo "$SRC_DIR/prebuilts/recoveries/G780F.zip"
            ;;
        "x1s")
            echo "$SRC_DIR/prebuilts/recoveries/G980F_G981B.zip"
            ;;
        "y2s")
            echo "$SRC_DIR/prebuilts/recoveries/G985F_G986B.zip"
            ;;
        "z3s")
            echo "$SRC_DIR/prebuilts/recoveries/G988B.zip"
            ;;
        "p3s")
            echo "$SRC_DIR/prebuilts/recoveries/G998B.zip"
            ;;
        "c1s")
            echo "$SRC_DIR/prebuilts/recoveries/N980F_N981B.zip"
            ;;
        "c2s")
            echo "$SRC_DIR/prebuilts/recoveries/N985F_N986B.zip"
            ;;
        *)
            echo "none"
            ;;
    esac
}

GET_DEFAULT_KEEP_ORIGINAL_SIGN()
{
    if [[ "$ROM_ENABLE_AVB" == "true" ]]; then
        echo "false"
    else
        echo "true"
    fi
}

GET_DEFAULT_AVB_KEY_PATH()
{
    if [[ "$ROM_ENABLE_AVB" == "true" ]]; then
        echo "$SRC_DIR/security/avb/creckerrom_avb_private.pem"
    else
        echo "none"
    fi
}

GET_DEFAULT_AVB_ALGORITHM()
{
    if [[ "$ROM_ENABLE_AVB" == "true" ]]; then
        echo "SHA256_RSA4096"
    else
        echo "SHA256_RSA4096"
    fi
}

GET_DEFAULT_AVB_INCLUDE_PARTITION_DESCRIPTORS()
{
    echo "${ROM_AVB_INCLUDE_PARTITION_DESCRIPTORS:-true}"
}

GET_DEFAULT_AVB_VBMETA_FLAGS()
{
    echo "0"
}

GET_DEFAULT_PLATFORM_KEY_SOURCE_PEM()
{
    local KEY_PATH
    KEY_PATH="$(GET_DEFAULT_AVB_KEY_PATH)"
    [ "$KEY_PATH" = "none" ] && KEY_PATH="$SRC_DIR/security/avb/creckerrom_avb_private.pem"
    echo "$KEY_PATH"
}

GET_DEFAULT_PLATFORM_CERT_X509_PATH()
{
    echo "$SRC_DIR/security/creckerrom_platform.x509.pem"
}

GET_DEFAULT_PLATFORM_CERT_PK8_PATH()
{
    echo "$SRC_DIR/security/creckerrom_platform.pk8"
}

GET_DEFAULT_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS()
{
    echo ""
}

GET_DEFAULT_AVB_FIRMWARE_IMAGE_MAP()
{
    echo ""
}

GET_DEFAULT_ODIN_EXTRA_PARTITIONS()
{
    GET_DEFAULT_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS
}

GET_DEFAULT_AVB_PRESERVE_SAMSUNG_SIGNATURES()
{
    echo "true"
}

GET_DEFAULT_SAMSUNG_SIGNING()
{
    if [ "${TARGET_PLATFORM:-}" = "exynos990" ] && [ "${ROM_ENABLE_AVB:-false}" = "true" ]; then
        echo "true"
    else
        echo "false"
    fi
}

GET_DEFAULT_SAMSUNG_SIGNING_DEPENDENT()
{
    if [ -n "${TARGET_ENABLE_SAMSUNG_SIGNING:-}" ]; then
        echo "$TARGET_ENABLE_SAMSUNG_SIGNING"
    else
        GET_DEFAULT_SAMSUNG_SIGNING
    fi
}

SET_SAMSUNG_BL1_METADATA()
{
    local ASSERT_MODEL
    local MODEL_IS_SUPPORTED=false
    local METADATA

    if [ ! "$ROM_AVB_MODEL" ]; then
        LOGE "AVB-enabled Exynos990 builds require --avb-model <model>"
        LOGE "Valid models: $(PRINT_SAMSUNG_BL1_SUPPORTED_MODELS)"
        exit 1
    fi

    if ! METADATA="$(GET_SAMSUNG_BL1_MODEL_METADATA "$ROM_AVB_MODEL")"; then
        LOGE "Unsupported Samsung BL1 model: $ROM_AVB_MODEL"
        LOGE "Valid models: $(PRINT_SAMSUNG_BL1_SUPPORTED_MODELS)"
        exit 1
    fi

    for ASSERT_MODEL in "${TARGET_ASSERT_MODEL[@]}"; do
        if [ "$ASSERT_MODEL" = "SM-$ROM_AVB_MODEL" ]; then
            MODEL_IS_SUPPORTED=true
            break
        fi
    done

    if ! $MODEL_IS_SUPPORTED; then
        LOGE "Samsung BL1 model $ROM_AVB_MODEL is not valid for target $TARGET_CODENAME"
        LOGE "Target models: ${TARGET_ASSERT_MODEL[*]}"
        exit 1
    fi

    TARGET_SAMSUNG_BL1_MODEL="$ROM_AVB_MODEL"
    read -r TARGET_SAMSUNG_BL1_MODEL_ID TARGET_SAMSUNG_BL1_EVT TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX <<< "$METADATA"
    TARGET_AVB_ROLLBACK_INDEX="$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX"
}

IS_DEFAULT_AVB_CONFIG_VAR()
{
    case "$1" in
        "TARGET_AVB_USE_ORIGINAL_VBMETA_LAYOUT" | \
        "TARGET_AVB_KEY_PATH" | \
        "TARGET_AVB_ALGORITHM" | \
        "TARGET_AVBTOOL_PATH" | \
        "TARGET_AVBTOOL_PYTHON" | \
        "TARGET_AVB_LOW_SECURITY" | \
        "TARGET_AVB_INCLUDE_PARTITION_DESCRIPTORS" | \
        "TARGET_AVB_PRESERVE_SAMSUNG_SIGNATURES" | \
        "TARGET_AVB_HASH_PARTITIONS" | \
        "TARGET_AVB_FIRMWARE_DESCRIPTOR_PARTITIONS" | \
        "TARGET_AVB_FIRMWARE_IMAGE_MAP" | \
        "TARGET_AVB_HASHTREE_PARTITIONS" | \
        "TARGET_AVB_CHAIN_PARTITIONS" | \
        "TARGET_AVB_ORIGINAL_VBMETA_PATH" | \
        "TARGET_AVB_ORIGINAL_VBMETA_SAMSUNG_PATH" | \
        "TARGET_AVB_VBMETA_SAMSUNG_PARTITIONS" | \
        "TARGET_AVB_ALLOW_HASHTREE_FALLBACK" | \
        "TARGET_AVB_ROLLBACK_INDEX" | \
        "TARGET_AVB_ROLLBACK_INDEX_LOCATION" | \
        "TARGET_AVB_HASH_ALGORITHM" | \
        "TARGET_AVB_VBMETA_FLAGS" | \
        "TARGET_AVB_MAKE_VBMETA_IMAGE_ARGS" | \
        "TARGET_AVB_MAKE_VBMETA_SAMSUNG_IMAGE_ARGS" | \
        "TARGET_ODIN_EXTRA_PARTITIONS" | \
        "TARGET_ODIN_EXTRA_IMAGE_MAP")
            return 0
            ;;
    esac

    return 1
}

IS_DEFAULT_SAMSUNG_CONFIG_VAR()
{
    case "$1" in
        "TARGET_ENABLE_SAMSUNG_SIGNING" | \
        "TARGET_SAMSUNG_SIGN_AP_IMAGES" | \
        "TARGET_SAMSUNG_SIGN_SUPER_IMAGES" | \
        "TARGET_SAMSUNG_SIGN_BOOTLOADER" | \
        "TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE" | \
        "TARGET_SAMSUNG_SIGNING_SOC" | \
        "TARGET_SAMSUNG_SIGNING_KEY_DIR" | \
        "TARGET_SAMSUNG_SUPER_REFERENCE_IMAGE" | \
        "TARGET_SAMSUNG_LK_PATCH_TABLE" | \
        "TARGET_SAMSUNG_ENABLE_KVM" | \
        "TARGET_SAMSUNG_EL3_PATCH_TABLE" | \
        "TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" | \
        "TARGET_SAMSUNG_AVBTOOL_PATH" | \
        "TARGET_SAMSUNG_AVB_KEY_PATH" | \
        "TARGET_SAMSUNG_AVB_ALGORITHM" | \
        "TARGET_SAMSUNG_UPDATE_KEYSTORAGE_VBMETA_KEY" | \
        "TARGET_SAMSUNG_KEYSTORAGE_VBMETA_KEY_PATH" | \
        "TARGET_SAMSUNG_TZAR_PATCH_FILE" | \
        "TARGET_SAMSUNG_TZAR_PATCH_TABLE" | \
        "TARGET_SAMSUNG_DECRYPTED_TZSW_PATH" | \
        "TARGET_SAMSUNG_BL1_MACHINE_ID" | \
        "TARGET_SAMSUNG_BL1_MODEL" | \
        "TARGET_SAMSUNG_BL1_MODEL_ID" | \
        "TARGET_SAMSUNG_BL1_EVT" | \
        "TARGET_SAMSUNG_FWBL1_SIZE")
            return 0
            ;;
    esac

    return 1
}

EMIT_EXTRA_AVB_VARS()
{
    local VAR

    while IFS= read -r VAR; do
        IS_DEFAULT_AVB_CONFIG_VAR "$VAR" && continue
        GET_BUILD_VAR "$VAR"
    done < <(compgen -v | grep '^TARGET_AVB_' || true)
}

EMIT_EXTRA_SAMSUNG_VARS()
{
    local VAR

    while IFS= read -r VAR; do
        IS_DEFAULT_SAMSUNG_CONFIG_VAR "$VAR" && continue
        GET_BUILD_VAR "$VAR"
    done < <(compgen -v | grep '^TARGET_SAMSUNG_' || true)
}
# ]
