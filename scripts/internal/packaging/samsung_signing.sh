SAMSUNG_DOWNLOAD_PARTITIONS="cache hidden userdata omr efs nad_bigstream dqmdbg sec_efs super prism optics spu metadata"

RUN_SAMSUNG_AP_IMAGE_SIGNING()
{
    local IMAGE_DIR="$1"
    local PHASE="$2"
    local FOOTER_REFERENCE="$FW_DIR/$TARGET_FIRMWARE_PATH/kernel/boot.img"
    local -a REFERENCE_ARGS=()
    local -a STRICT_ARGS=()

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_SIGN_AP_IMAGES || return 0

    if [ "$TARGET_PLATFORM" != "exynos990" ]; then
        LOGW "Samsung AP image signing is only enabled for TARGET_PLATFORM=exynos990; skipping $TARGET_PLATFORM"
        return 0
    fi

    [ "$PHASE" = "before-avb" ] && STRICT_ARGS+=(--strict)
    [ -f "$FOOTER_REFERENCE" ] && REFERENCE_ARGS+=(--footer-reference "$FOOTER_REFERENCE")

    python3 "$SRC_DIR/scripts/samsung_signing/sign_ap_images.py" \
        --images-dir "$IMAGE_DIR" \
        --keys-dir "$TARGET_SAMSUNG_SIGNING_KEY_DIR" \
        --phase "$PHASE" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --rollback "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" \
        "${REFERENCE_ARGS[@]}" \
        "${STRICT_ARGS[@]}" || exit 1
}

SAMSUNG_PRIVATE_KEY_FOR_TYPE()
{
    case "$1" in
        2)
            echo "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage3_private.pem"
            ;;
        1)
            echo "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_ree_private.pem"
            ;;
        *)
            echo "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_tee_private.pem"
            ;;
    esac
}

SAMSUNG_VERIFY_KEY_ARGS()
{
    echo "--tee-pub-key $TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_tee_pubkey.bin --ree-pub-key $TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_ree_pubkey.bin --stage3-pub-key $TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage3_pubkey.bin"
}

GET_TARGET_SUPER_REFERENCE_IMAGE()
{
    local CONFIGURED="$TARGET_SAMSUNG_SUPER_REFERENCE_IMAGE"
    local CACHE_PATH="$OUT_DIR/target/$TARGET_CODENAME/samsung_super_reference/super.img"
    local TAR_FILE=""
    local CANDIDATE

    if [ -n "$CONFIGURED" ] && [ "$CONFIGURED" != "auto" ] && [ "$CONFIGURED" != "none" ]; then
        [ -f "$CONFIGURED" ] || {
            LOGE "Configured target super reference image does not exist: $CONFIGURED"
            exit 1
        }
        echo "$CONFIGURED"
        return 0
    fi

    [ "$CONFIGURED" != "none" ] || return 1

    # super.img signing needs stock Samsung SignerInfo/header defaults; cache a
    # target AP super reference when it is not already extracted.
    for CANDIDATE in "$FW_DIR/$TARGET_FIRMWARE_PATH/super.img" "$CACHE_PATH"; do
        [ -f "$CANDIDATE" ] && echo "$CANDIDATE" && return 0
    done

    TAR_FILE="$(FIND_TARGET_ODIN_TAR "AP" || true)"
    [ -n "$TAR_FILE" ] && [ -f "$TAR_FILE" ] || {
        LOGE "Unable to find target AP Odin tar for super.img reference under $ODIN_DIR/$TARGET_FIRMWARE_PATH"
        exit 1
    }

    LOG "- Extracting target firmware super.img reference from $(basename "$TAR_FILE")" >&2
    EXTRACT_ODIN_TAR_ENTRY_TO_PATH "$TAR_FILE" "super.img" "$CACHE_PATH" || exit 1
    echo "$CACHE_PATH"
}

GET_EXISTING_STAGE2_KEY_TYPE()
{
    local IMAGE="$1"
    local STAGE="$2"

    # Preserve stock key_type when re-signing; key_type selects which Samsung
    # public key the boot chain will use for this stage.
    python3 - "$SRC_DIR" "$IMAGE" "$STAGE" <<'PY'
import sys

src_dir, image_path, stage = sys.argv[1:4]
sys.path.insert(0, f"{src_dir}/scripts/samsung_signing")

from stage2_common import (  # noqa: E402
    normalize_stage,
    parse_stage2_footer,
    read_file,
    stage2_footer_candidate_sizes,
)

stage = normalize_stage(stage)
data = read_file(image_path)
sizes = stage2_footer_candidate_sizes(stage, data)

if not sizes:
    raise SystemExit(1)

print(parse_stage2_footer(data, sizes[0]).key_type)
PY
}

GET_DOWNLOAD_SIGNATURE_KEY_TYPE()
{
    local IMAGE="$1"

    # Sparse download signatures also carry a key_type, independent of AVB.
    python3 - "$SRC_DIR" "$IMAGE" <<'PY'
import sys

src_dir, image_path = sys.argv[1:3]
sys.path.insert(0, f"{src_dir}/scripts/samsung_signing")

from download_signature_common import parse_download_signature_layout  # noqa: E402

try:
    print(parse_download_signature_layout(image_path).key_type)
except ValueError:
    raise SystemExit(1)
PY
}

GET_TARGET_DOWNLOAD_REFERENCE_IMAGE()
{
    local ENTRY_NAME="$1"
    local CACHE_PATH="$OUT_DIR/target/$TARGET_CODENAME/samsung_download_reference/$ENTRY_NAME"
    local CANDIDATE
    local PACKAGE_PREFIX
    local TAR_FILE=""

    for CANDIDATE in "$FW_DIR/$TARGET_FIRMWARE_PATH/$ENTRY_NAME" "$CACHE_PATH"; do
        [ -f "$CANDIDATE" ] && echo "$CANDIDATE" && return 0
    done

    # Samsung moves filesystem payloads between AP and CSC across releases.
    # Locate a stock signed image instead of assuming one package.
    for PACKAGE_PREFIX in CSC AP; do
        TAR_FILE="$(FIND_TARGET_ODIN_TAR "$PACKAGE_PREFIX" || true)"
        [ -n "$TAR_FILE" ] && [ -f "$TAR_FILE" ] || continue
        if FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME" || \
                FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME.lz4" || \
                FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME.ext4"; then
            LOG "- Extracting target firmware $ENTRY_NAME signature reference from $(basename "$TAR_FILE")" >&2
            EXTRACT_ODIN_TAR_ENTRY_TO_PATH "$TAR_FILE" "$ENTRY_NAME" "$CACHE_PATH" || exit 1
            echo "$CACHE_PATH"
            return 0
        fi
    done

    return 1
}

GET_SAMSUNG_DOWNLOAD_IMAGE_PATH()
{
    local IMAGE_DIR="$1"
    local PARTITION="$2"
    local COMPONENT_FILE=""

    COMPONENT_FILE="$(GET_KV_VALUE "$PARTITION" "${TARGET_ODIN_EXTRA_IMAGE_MAP:-}")"
    [ -n "$COMPONENT_FILE" ] || \
        COMPONENT_FILE="$(GET_KV_VALUE "$PARTITION" "${TARGET_AVB_FIRMWARE_IMAGE_MAP:-}")"
    [ -n "$COMPONENT_FILE" ] || COMPONENT_FILE="$PARTITION.img"
    echo "$IMAGE_DIR/$COMPONENT_FILE"
}

PREPARE_DOWNLOAD_ODIN_COMPONENT_FOR_AVB()
{
    local IMAGE="$1"
    local PARTITION="${2:-}"
    local REFERENCE=""
    local PREPARED_TMP="$IMAGE.download-avb.tmp"

    [ -f "$IMAGE" ] || return 0
    REFERENCE="$(GET_TARGET_DOWNLOAD_REFERENCE_IMAGE "$(basename "$IMAGE")" || true)"
    if [ -z "$REFERENCE" ] && [ -n "$PARTITION" ] && \
            [ "$(basename "$IMAGE")" != "$PARTITION.img" ]; then
        REFERENCE="$(GET_TARGET_DOWNLOAD_REFERENCE_IMAGE "$PARTITION.img" || true)"
    fi
    [ -n "$REFERENCE" ] && [ -f "$REFERENCE" ] || {
        LOGE "$(basename "$IMAGE") needs a signed stock reference to initialize its pre-AVB download signer block"
        exit 1
    }

    rm -f "$PREPARED_TMP"
    LOG "- Preparing $(basename "$IMAGE") Samsung download signer block before AVB"
    python3 "$SRC_DIR/scripts/samsung_signing/download_prepare_avb_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        -o "$PREPARED_TMP" \
        --reference "$REFERENCE" \
        -r "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" || exit 1
    mv -f "$PREPARED_TMP" "$IMAGE"
}

PREPARE_SAMSUNG_DOWNLOAD_IMAGES_FOR_AVB()
{
    local IMAGE_DIR="$1"
    local PARTITION
    local IMAGE

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_SIGN_AP_IMAGES || return 0
    $TARGET_ENABLE_CUSTOM_AVB || return 0
    $TARGET_AVB_LOW_SECURITY && return 0

    for PARTITION in $SAMSUNG_DOWNLOAD_PARTITIONS; do
        # super.img is assembled after the AVB pass from already signed logical
        # partitions and has no AVB footer of its own.
        [ "$PARTITION" = "super" ] && continue
        IMAGE="$(GET_SAMSUNG_DOWNLOAD_IMAGE_PATH "$IMAGE_DIR" "$PARTITION")"
        [ -f "$IMAGE" ] || continue
        PREPARE_DOWNLOAD_ODIN_COMPONENT_FOR_AVB "$IMAGE" "$PARTITION"
    done
}

SIGN_SUPER_IMAGE_IF_REQUIRED()
{
    local IMAGE="$1"
    local REFERENCE=""
    local KEY_TYPE=""
    local PRIVATE_KEY=""
    local SIGNED_TMP=""
    local VERIFY_ARGS

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_SIGN_SUPER_IMAGES || return 0
    [ -f "$IMAGE" ] || return 0

    if [ "$TARGET_PLATFORM" != "exynos990" ]; then
        LOGW "Samsung super.img signing is only enabled for TARGET_PLATFORM=exynos990; skipping $(basename "$IMAGE")"
        return 0
    fi

    REFERENCE="$(GET_TARGET_SUPER_REFERENCE_IMAGE || true)"
    [ -n "$REFERENCE" ] && [ -f "$REFERENCE" ] || {
        LOGE "Samsung super.img signing needs a signed target firmware super.img reference"
        exit 1
    }

    KEY_TYPE="$(GET_DOWNLOAD_SIGNATURE_KEY_TYPE "$REFERENCE" || true)"
    [ -n "$KEY_TYPE" ] || {
        LOGE "Target super reference has no recognizable sparse download signature layout: $REFERENCE"
        exit 1
    }

    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY_FOR_TYPE "$KEY_TYPE")"
    [ -f "$PRIVATE_KEY" ] || {
        LOGE "Missing Samsung private key for super key_type=$KEY_TYPE: $PRIVATE_KEY"
        exit 1
    }

    SIGNED_TMP="$IMAGE.signed.tmp"
    rm -f "$SIGNED_TMP"
    LOG "- Samsung-signing $(basename "$IMAGE") download signature using target firmware super.img reference, key_type=$KEY_TYPE"
    python3 "$SRC_DIR/scripts/samsung_signing/download_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        -o "$SIGNED_TMP" \
        -k "$PRIVATE_KEY" \
        -r "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" \
        --key-type "$KEY_TYPE" \
        --super \
        --super-reference "$REFERENCE" || exit 1
    mv -f "$SIGNED_TMP" "$IMAGE"

    VERIFY_ARGS="$(SAMSUNG_VERIFY_KEY_ARGS)"
    # shellcheck disable=SC2086
    python3 "$SRC_DIR/scripts/samsung_signing/download_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        $VERIFY_ARGS || exit 1
}

SIGN_STAGE2_ODIN_COMPONENT()
{
    local IMAGE="$1"
    local STAGE="$2"
    local REQUIRED="$3"
    local KEY_TYPE=""
    local PRIVATE_KEY=""
    local VERIFY_ARGS

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    if [ "$TARGET_PLATFORM" != "exynos990" ]; then
        LOGW "Samsung Stage-2 Odin firmware signing is only enabled for TARGET_PLATFORM=exynos990; skipping $(basename "$IMAGE")"
        return 0
    fi

    KEY_TYPE="$(GET_EXISTING_STAGE2_KEY_TYPE "$IMAGE" "$STAGE" || true)"
    if [ -z "$KEY_TYPE" ]; then
        if [ "$REQUIRED" = "true" ]; then
            LOGE "$(basename "$IMAGE") has no recognizable Samsung Stage-2 footer/trailer"
            exit 1
        fi
        LOGW "$(basename "$IMAGE") has no recognizable Samsung Stage-2 footer/trailer; keeping stock"
        return 0
    fi

    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY_FOR_TYPE "$KEY_TYPE")"
    [ -f "$PRIVATE_KEY" ] || {
        LOGE "Missing Samsung private key for key_type=$KEY_TYPE: $PRIVATE_KEY"
        exit 1
    }

    LOG "- Samsung-signing $(basename "$IMAGE") as $STAGE, key_type=$KEY_TYPE"
    python3 "$SRC_DIR/scripts/samsung_signing/stage2_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --stage "$STAGE" \
        -i "$IMAGE" \
        -o "$IMAGE" \
        -k "$PRIVATE_KEY" \
        -r "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" \
        --key-type "$KEY_TYPE" || exit 1

    VERIFY_ARGS="$(SAMSUNG_VERIFY_KEY_ARGS)"
    # shellcheck disable=SC2086
    python3 "$SRC_DIR/scripts/samsung_signing/stage2_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --stage "$STAGE" \
        -i "$IMAGE" \
        $VERIFY_ARGS || exit 1
}

VERIFY_STAGE2_ODIN_COMPONENT()
{
    local IMAGE="$1"
    local STAGE="$2"
    local MODE="${3:-auto}"
    local INNER="${4:-auto}"
    local VERIFY_ARGS

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    [ -f "$IMAGE" ] || return 0

    VERIFY_ARGS="$(SAMSUNG_VERIFY_KEY_ARGS)"
    # shellcheck disable=SC2086
    python3 "$SRC_DIR/scripts/samsung_signing/stage2_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --stage "$STAGE" \
        -i "$IMAGE" \
        --mode "$MODE" \
        --inner "$INNER" \
        $VERIFY_ARGS || exit 1
}

VERIFY_SAMSUNG_STAGE2_IMAGES_IN_DIR()
{
    local IMAGE_DIR="$1"
    local ENTRY
    local PARTITION
    local FILENAME
    local DEFAULT_FILENAME
    local STAGE
    local STAGE2_IMAGES="boot:boot:boot.img dtbo:dtbo:dtbo.img recovery:recovery:recovery.img vendor_boot:vendor_boot:vendor_boot.img init_boot:init_boot:init_boot.img misc:misc:misc.bin vbmeta:vbmeta:vbmeta.img vbmeta_samsung:vbmeta_samsung:vbmeta_samsung.img"

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_SIGN_AP_IMAGES || return 0
    for ENTRY in $STAGE2_IMAGES; do
        PARTITION="${ENTRY%%:*}"
        ENTRY="${ENTRY#*:}"
        STAGE="${ENTRY%%:*}"
        DEFAULT_FILENAME="${ENTRY#*:}"
        FILENAME="$(GET_KV_VALUE "$PARTITION" "${TARGET_ODIN_EXTRA_IMAGE_MAP:-}")"
        [ -n "$FILENAME" ] || \
            FILENAME="$(GET_KV_VALUE "$PARTITION" "${TARGET_AVB_FIRMWARE_IMAGE_MAP:-}")"
        [ -n "$FILENAME" ] || FILENAME="$DEFAULT_FILENAME"
        [ -f "$IMAGE_DIR/$FILENAME" ] || continue
        VERIFY_STAGE2_ODIN_COMPONENT "$IMAGE_DIR/$FILENAME" "$STAGE"
    done
}

VERIFY_SAMSUNG_BOOTLOADER_STAGE2_IMAGES_IN_DIR()
{
    local IMAGE_DIR="$1"
    local ENTRY
    local FILENAME
    local STAGE
    local STAGE2_IMAGES="sboot.bin:sboot ldfw.img:ldfw tzsw.img:tzsw keystorage.bin:keystorage harx.bin:harx tzar.img:tzar uh.bin:uh"

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_SIGN_BOOTLOADER || return 0
    for ENTRY in $STAGE2_IMAGES; do
        FILENAME="${ENTRY%%:*}"
        STAGE="${ENTRY#*:}"
        [ -f "$IMAGE_DIR/$FILENAME" ] || continue
        if [ "$FILENAME" = "sboot.bin" ]; then
            VERIFY_STAGE2_ODIN_COMPONENT \
                "$IMAGE_DIR/$FILENAME" "$STAGE" "avb" "no"
        else
            VERIFY_STAGE2_ODIN_COMPONENT "$IMAGE_DIR/$FILENAME" "$STAGE"
        fi
    done
    [ -f "$IMAGE_DIR/sboot.bin" ] && VERIFY_SAMSUNG_SBOOT_SPLITS "$IMAGE_DIR/sboot.bin"
}

VERIFY_SAMSUNG_SBOOT_SPLITS()
{
    local SBOOT_IMAGE="$1"
    local VERIFY_ROOT="$OUT_DIR/target/$TARGET_CODENAME"
    local VERIFY_DIR
    local ENTRY
    local FILENAME
    local STAGE
    local SPLIT_IMAGES="epbl.img:epbl bl2.img:bl2 lk.bin:lk el3_mon.img:el3_mon"

    mkdir -p "$VERIFY_ROOT"
    VERIFY_DIR="$(mktemp -d "$VERIFY_ROOT/sboot_verify.XXXXXX")" || exit 1
    LOG "- Splitting final $(basename "$SBOOT_IMAGE") for Stage-2 verification"
    python3 "$SRC_DIR/scripts/samsung_signing/split.py" \
        "$SBOOT_IMAGE" --soc Exynos9830 -o "$VERIFY_DIR" || exit 1
    for ENTRY in $SPLIT_IMAGES; do
        FILENAME="${ENTRY%%:*}"
        STAGE="${ENTRY#*:}"
        [ -f "$VERIFY_DIR/$FILENAME" ] || {
            LOGE "Final sboot split is missing $FILENAME"
            exit 1
        }
        VERIFY_STAGE2_ODIN_COMPONENT "$VERIFY_DIR/$FILENAME" "$STAGE"
    done
    # fwbl1.img is BL1-signed/HMAC-bound. This repository does not have an
    # independent BL1/HMAC verifier, so do not misclassify it as verified here.
    rm -rf "$VERIFY_DIR"
}

VERIFY_DOWNLOAD_ODIN_COMPONENT()
{
    local IMAGE="$1"
    local VERIFY_ARGS

    [ -f "$IMAGE" ] || return 1
    VERIFY_ARGS="$(SAMSUNG_VERIFY_KEY_ARGS)"
    # shellcheck disable=SC2086
    python3 "$SRC_DIR/scripts/samsung_signing/download_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        $VERIFY_ARGS
}

VERIFY_AVB_AFTER_DOWNLOAD_ODIN_COMPONENT()
{
    local IMAGE="$1"
    local AVB_INFO=""
    local AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-$SRC_DIR/external/android-tools/vendor/avb/avbtool.py}"
    local AVB_KEY_PATH="${TARGET_AVB_KEY_PATH:-$SRC_DIR/security/avb/creckerrom_avb_private.pem}"

    $TARGET_ENABLE_CUSTOM_AVB || return 0
    $TARGET_AVB_LOW_SECURITY && return 0
    AVB_INFO="$(GET_ODIN_COMPONENT_AVB_INFO "$IMAGE" || true)"
    [ -n "$AVB_INFO" ] || return 0

    python3 "$SRC_DIR/scripts/samsung_signing/download_avb_verify_tool.py" \
        -i "$IMAGE" \
        --avbtool "$AVBTOOL_PATH" \
        --key "$AVB_KEY_PATH" || exit 1
}

SIGN_DOWNLOAD_ODIN_COMPONENT()
{
    local IMAGE="$1"
    local REQUIRED="$2"
    local PARTITION="${3:-}"
    local KEY_TYPE=""
    local PRIVATE_KEY=""
    local SIGNED_TMP
    local REFERENCE=""
    local -a REFERENCE_ARGS=()

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    if [ "$TARGET_PLATFORM" != "exynos990" ]; then
        LOGW "Samsung download Odin firmware signing is only enabled for TARGET_PLATFORM=exynos990; skipping $(basename "$IMAGE")"
        return 0
    fi

    KEY_TYPE="$(GET_DOWNLOAD_SIGNATURE_KEY_TYPE "$IMAGE" || true)"
    if [ -z "$KEY_TYPE" ]; then
        REFERENCE="$(GET_TARGET_DOWNLOAD_REFERENCE_IMAGE "$(basename "$IMAGE")" || true)"
        if [ -z "$REFERENCE" ] && [ -n "$PARTITION" ] && \
                [ "$(basename "$IMAGE")" != "$PARTITION.img" ]; then
            REFERENCE="$(GET_TARGET_DOWNLOAD_REFERENCE_IMAGE "$PARTITION.img" || true)"
        fi
        if [ -n "$REFERENCE" ] && [ -f "$REFERENCE" ]; then
            KEY_TYPE="$(GET_DOWNLOAD_SIGNATURE_KEY_TYPE "$REFERENCE" || true)"
            REFERENCE_ARGS=(--reference "$REFERENCE")
        fi
        if [ -z "$KEY_TYPE" ]; then
            if [ "$REQUIRED" = "true" ]; then
                LOGE "$(basename "$IMAGE") has no sparse download signer block and no signed target reference"
                exit 1
            fi
            LOGW "$(basename "$IMAGE") has no recognizable sparse download signature layout; keeping stock"
            return 0
        fi
    fi

    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY_FOR_TYPE "$KEY_TYPE")"
    [ -f "$PRIVATE_KEY" ] || {
        LOGE "Missing Samsung private key for key_type=$KEY_TYPE: $PRIVATE_KEY"
        exit 1
    }

    SIGNED_TMP="$IMAGE.signed.tmp"
    rm -f "$SIGNED_TMP"
    LOG "- Samsung-signing $(basename "$IMAGE") download signature, key_type=$KEY_TYPE"
    python3 "$SRC_DIR/scripts/samsung_signing/download_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        -o "$SIGNED_TMP" \
        -k "$PRIVATE_KEY" \
        -r "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" \
        "${REFERENCE_ARGS[@]}" || exit 1
    mv -f "$SIGNED_TMP" "$IMAGE"

    VERIFY_DOWNLOAD_ODIN_COMPONENT "$IMAGE" || exit 1
}

ENSURE_DOWNLOAD_ODIN_COMPONENT()
{
    local IMAGE="$1"
    local PARTITION="$2"
    local VERIFY_OUTPUT=""

    [ -f "$IMAGE" ] || return 0
    # Do not rewrite a byte-identical signed payload copied from another final
    # directory. Still print the verifier's full result for the build audit.
    if VERIFY_OUTPUT="$(VERIFY_DOWNLOAD_ODIN_COMPONENT "$IMAGE" 2>&1)"; then
        printf '%s\n' "$VERIFY_OUTPUT"
        VERIFY_AVB_AFTER_DOWNLOAD_ODIN_COMPONENT "$IMAGE"
        return 0
    fi

    if [ "$PARTITION" = "super" ]; then
        SIGN_SUPER_IMAGE_IF_REQUIRED "$IMAGE"
    else
        SIGN_DOWNLOAD_ODIN_COMPONENT "$IMAGE" "true" "$PARTITION"
    fi
    VERIFY_AVB_AFTER_DOWNLOAD_ODIN_COMPONENT "$IMAGE"
}

FINALIZE_SAMSUNG_DOWNLOAD_IMAGES_IN_DIR()
{
    local IMAGE_DIR="$1"
    local PARTITION
    local IMAGE

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_SIGN_AP_IMAGES || return 0
    [ -d "$IMAGE_DIR" ] || return 0

    for PARTITION in $SAMSUNG_DOWNLOAD_PARTITIONS; do
        [ "$PARTITION" != "super" ] || $TARGET_SAMSUNG_SIGN_SUPER_IMAGES || continue
        IMAGE="$(GET_SAMSUNG_DOWNLOAD_IMAGE_PATH "$IMAGE_DIR" "$PARTITION")"
        [ -f "$IMAGE" ] || continue
        ENSURE_DOWNLOAD_ODIN_COMPONENT "$IMAGE" "$PARTITION"
    done
}

FIND_TARGET_ODIN_TAR()
{
    local PREFIX="$1"
    local FW_ODIN_DIR="$ODIN_DIR/$TARGET_FIRMWARE_PATH"
    local MODEL_ALT="${TARGET_FIRMWARE_MODEL#SM-}"
    local PATTERN
    local TAR_FILE=""

    [ -d "$FW_ODIN_DIR" ] || return 1

    for PATTERN in \
        "${PREFIX}_${TARGET_FIRMWARE_MODEL}"*.md5 \
        "${PREFIX}_${MODEL_ALT}"*.md5 \
        "${PREFIX}_"*.md5 \
        "${PREFIX}_${TARGET_FIRMWARE_MODEL}"*.tar \
        "${PREFIX}_${MODEL_ALT}"*.tar \
        "${PREFIX}_"*.tar; do
        TAR_FILE="$(find "$FW_ODIN_DIR" -maxdepth 1 -name "$PATTERN" | sort -r | head -n 1)"
        [ -n "$TAR_FILE" ] && break
    done

    [ -n "$TAR_FILE" ] && echo "$TAR_FILE"
}

EXTRACT_ODIN_TAR_ENTRY_TO_PATH()
{
    local TAR_FILE="$1"
    local ENTRY_NAME="$2"
    local OUTPUT_PATH="$3"
    local OUTPUT_DIR

    OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT_PATH" "$OUTPUT_DIR/$ENTRY_NAME" "$OUTPUT_DIR/$ENTRY_NAME.lz4" "$OUTPUT_DIR/$ENTRY_NAME.ext4"

    if FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME"; then
        tar xf "$TAR_FILE" -C "$OUTPUT_DIR" "$ENTRY_NAME" || exit 1
        [ "$OUTPUT_DIR/$ENTRY_NAME" = "$OUTPUT_PATH" ] || mv -f "$OUTPUT_DIR/$ENTRY_NAME" "$OUTPUT_PATH"
    elif FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME.lz4"; then
        tar xf "$TAR_FILE" -C "$OUTPUT_DIR" "$ENTRY_NAME.lz4" || exit 1
        lz4 -d --rm "$OUTPUT_DIR/$ENTRY_NAME.lz4" "$OUTPUT_PATH" > /dev/null || exit 1
    elif FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME.ext4"; then
        tar xf "$TAR_FILE" -C "$OUTPUT_DIR" "$ENTRY_NAME.ext4" || exit 1
        mv -f "$OUTPUT_DIR/$ENTRY_NAME.ext4" "$OUTPUT_PATH"
    else
        return 1
    fi

    chmod u+w "$OUTPUT_PATH"
    [ -f "$OUTPUT_PATH" ]
}

GET_ODIN_COMPONENT_AVB_INFO()
{
    local IMAGE="$1"
    local AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-$SRC_DIR/external/android-tools/vendor/avb/avbtool.py}"
    local AVB_PYTHON="${TARGET_AVBTOOL_PYTHON:-python3}"
    local FALLBACK_PARTITION

    [ "$AVBTOOL_PATH" != "none" ] || AVBTOOL_PATH="$SRC_DIR/external/android-tools/vendor/avb/avbtool.py"
    [ "$AVB_PYTHON" != "none" ] || AVB_PYTHON="python3"
    [ -f "$AVBTOOL_PATH" ] || return 0

    FALLBACK_PARTITION="$(basename "$IMAGE")"
    FALLBACK_PARTITION="${FALLBACK_PARTITION%.*}"
    "$AVB_PYTHON" "$SRC_DIR/scripts/samsung_signing/avb_cli.py" \
        --avbtool "$AVBTOOL_PATH" footer --image "$IMAGE" \
        --fallback-partition "$FALLBACK_PARTITION"
}

SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED()
{
    local IMAGE="$1"
    local ENTRY_NAME="$2"
    local AVB_INFO="${3:-}"
    local KIND
    local PARTITION_NAME
    local HASH_ALGORITHM
    local ROLLBACK_INDEX
    local ROLLBACK_INDEX_LOCATION
    local DO_NOT_USE_AB
    local CHECK_AT_MOST_ONCE
    local DO_NOT_GENERATE_FEC
    local PARTITION_SIZE
    local AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-$SRC_DIR/external/android-tools/vendor/avb/avbtool.py}"
    local AVB_PYTHON="${TARGET_AVBTOOL_PYTHON:-python3}"
    local AVB_KEY_PATH="${TARGET_AVB_KEY_PATH:-$SRC_DIR/security/avb/creckerrom_avb_private.pem}"
    local AVB_ALGORITHM="${TARGET_AVB_ALGORITHM:-SHA256_RSA4096}"
    local CMD=()

    $TARGET_ENABLE_CUSTOM_AVB || return 0
    if $TARGET_AVB_LOW_SECURITY; then
        LOG "- Skipping AVB footer signing for Odin firmware component $ENTRY_NAME (low-security mode)"
        return 0
    fi
    [ -f "$IMAGE" ] || return 0

    [ -n "$AVB_INFO" ] || AVB_INFO="$(GET_ODIN_COMPONENT_AVB_INFO "$IMAGE" || true)"
    [ -n "$AVB_INFO" ] || return 0

    # Replay the original AVB footer fields while replacing only the signing
    # key and configured rollback index.
    IFS=$'\t' read -r KIND PARTITION_NAME HASH_ALGORITHM ROLLBACK_INDEX ROLLBACK_INDEX_LOCATION \
        DO_NOT_USE_AB CHECK_AT_MOST_ONCE DO_NOT_GENERATE_FEC <<< "$AVB_INFO"
    ROLLBACK_INDEX="${TARGET_AVB_ROLLBACK_INDEX:-0}"

    [ "$AVBTOOL_PATH" != "none" ] || AVBTOOL_PATH="$SRC_DIR/external/android-tools/vendor/avb/avbtool.py"
    [ "$AVB_PYTHON" != "none" ] || AVB_PYTHON="python3"
    [ -f "$AVBTOOL_PATH" ] || {
        LOGE "AVB tool not found for Odin firmware component signing: $AVBTOOL_PATH"
        exit 1
    }
    [ -f "$AVB_KEY_PATH" ] || {
        LOGE "AVB key not found for Odin firmware component signing: $AVB_KEY_PATH"
        exit 1
    }

    # Opaque Odin components use their current file length as the partition
    # size, matching the stock firmware image layout.
    PARTITION_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || exit 1
    [ -n "$HASH_ALGORITHM" ] || HASH_ALGORITHM="${TARGET_AVB_HASH_ALGORITHM:-sha256}"

    LOG "- AVB-signing Odin firmware component $ENTRY_NAME ($KIND, partition=$PARTITION_NAME)"
    PATH="$SRC_DIR/scripts/internal:$PATH" \
        "$AVB_PYTHON" "$AVBTOOL_PATH" erase_footer --image "$IMAGE" || exit 1

    if [ "$KIND" = "hashtree" ]; then
        CMD=(
            add_hashtree_footer
            --image "$IMAGE"
            --partition_name "$PARTITION_NAME"
            --partition_size "$PARTITION_SIZE"
            --hash_algorithm "$HASH_ALGORITHM"
            --rollback_index "$ROLLBACK_INDEX"
            --rollback_index_location "$ROLLBACK_INDEX_LOCATION"
            --algorithm "$AVB_ALGORITHM"
            --key "$AVB_KEY_PATH"
        )
        [ "$DO_NOT_GENERATE_FEC" = "1" ] && CMD+=(--do_not_generate_fec)
        [ "$CHECK_AT_MOST_ONCE" = "1" ] && CMD+=(--check_at_most_once)
    else
        CMD=(
            add_hash_footer
            --image "$IMAGE"
            --partition_name "$PARTITION_NAME"
            --partition_size "$PARTITION_SIZE"
            --hash_algorithm "$HASH_ALGORITHM"
            --rollback_index "$ROLLBACK_INDEX"
            --rollback_index_location "$ROLLBACK_INDEX_LOCATION"
            --algorithm "$AVB_ALGORITHM"
            --key "$AVB_KEY_PATH"
        )
    fi
    [ "$DO_NOT_USE_AB" = "1" ] && CMD+=(--do_not_use_ab)

    PATH="$SRC_DIR/scripts/internal:$PATH" \
        "$AVB_PYTHON" "$AVBTOOL_PATH" "${CMD[@]}" || exit 1
    PATH="$SRC_DIR/scripts/internal:$PATH" \
        "$AVB_PYTHON" "$AVBTOOL_PATH" verify_image \
        --image "$IMAGE" --key "$AVB_KEY_PATH" || exit 1
}

PREPARE_ODIN_COMPONENT()
{
    local PACKAGE_PREFIX="$1"
    local ENTRY_NAME="$2"
    local OUTPUT_PATH="$3"
    local SIGN_KIND="$4"
    local SIGN_STAGE="$5"
    local REQUIRED_SIGN="${6:-true}"
    local TAR_FILE=""
    local CACHE_DIR
    local CACHE_PATH
    local AVB_INFO=""

    CACHE_DIR="$(tr '[:upper:]' '[:lower:]' <<< "$PACKAGE_PREFIX")"
    CACHE_PATH="$FW_DIR/$TARGET_FIRMWARE_PATH/odin_extra/$CACHE_DIR/$ENTRY_NAME"
    if [ -f "$CACHE_PATH" ]; then
        LOG "- Copying cached Odin firmware component $ENTRY_NAME"
        mkdir -p "$(dirname "$OUTPUT_PATH")"
        cp -fa "$CACHE_PATH" "$OUTPUT_PATH"
        chmod u+w "$OUTPUT_PATH"
        # Read AVB metadata before either signing layer mutates the bytes.
        AVB_INFO="$(GET_ODIN_COMPONENT_AVB_INFO "$OUTPUT_PATH" || true)"
        case "$SIGN_KIND" in
            "download")
                # AVB hashes the representation LK writes: final signer
                # metadata with FullHashSig zero. The outer signature itself
                # is filled only after AVB finalizes the sparse stream.
                [ -z "$AVB_INFO" ] || PREPARE_DOWNLOAD_ODIN_COMPONENT_FOR_AVB "$OUTPUT_PATH"
                SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED "$OUTPUT_PATH" "$ENTRY_NAME" "$AVB_INFO"
                SIGN_DOWNLOAD_ODIN_COMPONENT "$OUTPUT_PATH" "$REQUIRED_SIGN"
                ;;
            "stage2")
                # AVB authenticates the already Samsung-signed base payload.
                SIGN_STAGE2_ODIN_COMPONENT "$OUTPUT_PATH" "$SIGN_STAGE" "$REQUIRED_SIGN"
                SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED "$OUTPUT_PATH" "$ENTRY_NAME" "$AVB_INFO"
                ;;
            *)
                SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED "$OUTPUT_PATH" "$ENTRY_NAME" "$AVB_INFO"
                ;;
        esac
        return 0
    fi

    TAR_FILE="$(FIND_TARGET_ODIN_TAR "$PACKAGE_PREFIX" || true)"
    if [ -z "$TAR_FILE" ]; then
        LOGW "No $PACKAGE_PREFIX Odin tar found under $ODIN_DIR/$TARGET_FIRMWARE_PATH; skipping $ENTRY_NAME"
        return 0
    fi

    if ! FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME" && \
            ! FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME.lz4" && \
            ! FILE_EXISTS_IN_TAR "$TAR_FILE" "$ENTRY_NAME.ext4"; then
        LOGW "$ENTRY_NAME was not found in $(basename "$TAR_FILE"); skipping"
        return 0
    fi

    LOG "- Extracting $ENTRY_NAME from $(basename "$TAR_FILE")"
    EXTRACT_ODIN_TAR_ENTRY_TO_PATH "$TAR_FILE" "$ENTRY_NAME" "$OUTPUT_PATH" || exit 1
    # Keep original AVB footer metadata before applying Samsung signatures.
    AVB_INFO="$(GET_ODIN_COMPONENT_AVB_INFO "$OUTPUT_PATH" || true)"

    case "$SIGN_KIND" in
        "download")
            [ -z "$AVB_INFO" ] || PREPARE_DOWNLOAD_ODIN_COMPONENT_FOR_AVB "$OUTPUT_PATH"
            SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED "$OUTPUT_PATH" "$ENTRY_NAME" "$AVB_INFO"
            SIGN_DOWNLOAD_ODIN_COMPONENT "$OUTPUT_PATH" "$REQUIRED_SIGN"
            ;;
        "stage2")
            SIGN_STAGE2_ODIN_COMPONENT "$OUTPUT_PATH" "$SIGN_STAGE" "$REQUIRED_SIGN"
            SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED "$OUTPUT_PATH" "$ENTRY_NAME" "$AVB_INFO"
            ;;
        *)
            SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED "$OUTPUT_PATH" "$ENTRY_NAME" "$AVB_INFO"
            ;;
    esac
}
