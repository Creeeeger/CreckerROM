#!/usr/bin/env bash
#
# Copyright (C) 2023 Salvo Giangreco
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# [
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_CSC="$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

SOURCE_FINGERPRINT="$(GET_PROP "$WORK_DIR/system/system/build.prop" "ro.system.build.fingerprint")"
SOURCE_FINGERPRINT="${SOURCE_FINGERPRINT//$(GET_PROP "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/build.prop" "ro.build.product")/$(GET_PROP "$FW_DIR/$SOURCE_FIRMWARE_PATH/vendor/build.prop" "ro.product.vendor.device")}"
TARGET_FINGERPRINT="$(GET_PROP "$WORK_DIR/vendor/build.prop" "ro.vendor.build.fingerprint")"
TARGET_FINGERPRINT="${TARGET_FINGERPRINT//$(GET_PROP "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/build.prop" "ro.build.product")/$(GET_PROP "$FW_DIR/$TARGET_FIRMWARE_PATH/vendor/build.prop" "ro.product.vendor.device")}"

TMP_DIR="$OUT_DIR/zip"
TARGET_BUILD_FLASHABLE_ZIP="${TARGET_BUILD_FLASHABLE_ZIP:-false}"
TARGET_BUILD_ODIN_PACKAGE="${TARGET_BUILD_ODIN_PACKAGE:-true}"
TARGET_BUILD_HEIMDALL_PACKAGE="${TARGET_BUILD_HEIMDALL_PACKAGE:-true}"
TARGET_ODIN_USE_SUPER_IMAGE="${TARGET_ODIN_USE_SUPER_IMAGE:-false}"
TARGET_ODIN_EXTRA_PARTITIONS="${TARGET_ODIN_EXTRA_PARTITIONS:-}"
TARGET_ODIN_EXTRA_IMAGE_MAP="${TARGET_ODIN_EXTRA_IMAGE_MAP:-${TARGET_AVB_FIRMWARE_IMAGE_MAP:-}}"
TARGET_BUILD_ODIN_CP_PACKAGE="${TARGET_BUILD_ODIN_CP_PACKAGE:-true}"
TARGET_BUILD_ODIN_CSC_PACKAGE="${TARGET_BUILD_ODIN_CSC_PACKAGE:-true}"
TARGET_RECOVERY_IMAGE_PATH="${TARGET_RECOVERY_IMAGE_PATH:-none}"
TARGET_ROM_ZIP_COMPRESSION_LEVEL="${TARGET_ROM_ZIP_COMPRESSION_LEVEL:-5}"
TARGET_BROTLI_QUALITY="${TARGET_BROTLI_QUALITY:-4}"
TARGET_ENABLE_SAMSUNG_SIGNING="${TARGET_ENABLE_SAMSUNG_SIGNING:-false}"
TARGET_SAMSUNG_SIGN_AP_IMAGES="${TARGET_SAMSUNG_SIGN_AP_IMAGES:-$TARGET_ENABLE_SAMSUNG_SIGNING}"
TARGET_SAMSUNG_SIGN_SUPER_IMAGES="${TARGET_SAMSUNG_SIGN_SUPER_IMAGES:-$TARGET_SAMSUNG_SIGN_AP_IMAGES}"
TARGET_SAMSUNG_SIGN_BOOTLOADER="${TARGET_SAMSUNG_SIGN_BOOTLOADER:-$TARGET_ENABLE_SAMSUNG_SIGNING}"
TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE="${TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE:-$TARGET_SAMSUNG_SIGN_BOOTLOADER}"
TARGET_SAMSUNG_SIGNING_SOC="${TARGET_SAMSUNG_SIGNING_SOC:-exynos990}"
TARGET_SAMSUNG_SIGNING_KEY_DIR="${TARGET_SAMSUNG_SIGNING_KEY_DIR:-$SRC_DIR/security/samsung/exynos9830_crecker}"
TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX="${TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX:-23}"
TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR="${TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR:-$OUT_DIR/target/$TARGET_CODENAME/signed_bootloader}"
TARGET_SAMSUNG_SUPER_REFERENCE_IMAGE="${TARGET_SAMSUNG_SUPER_REFERENCE_IMAGE:-auto}"

if ! [[ "$TARGET_ROM_ZIP_COMPRESSION_LEVEL" =~ ^[0-9]$ ]]; then
    LOGW "Invalid TARGET_ROM_ZIP_COMPRESSION_LEVEL: $TARGET_ROM_ZIP_COMPRESSION_LEVEL (expected 0-9). Using 5."
    TARGET_ROM_ZIP_COMPRESSION_LEVEL="5"
fi

if ! [[ "$TARGET_BROTLI_QUALITY" =~ ^([0-9]|1[01])$ ]]; then
    LOGW "Invalid TARGET_BROTLI_QUALITY: $TARGET_BROTLI_QUALITY (expected 0-11). Using 4."
    TARGET_BROTLI_QUALITY="4"
fi

if [ "$TARGET_BUILD_HEIMDALL_PACKAGE" != "true" ] && [ "$TARGET_BUILD_HEIMDALL_PACKAGE" != "false" ]; then
    LOGW "Invalid TARGET_BUILD_HEIMDALL_PACKAGE: $TARGET_BUILD_HEIMDALL_PACKAGE (expected true|false). Using true."
    TARGET_BUILD_HEIMDALL_PACKAGE="true"
fi

ROM_DISPLAY_NAME="${ROM_DISPLAY_NAME:-CROM-S24FE-Official-${ROM_VERSION}}"

ZIP_FILE_SUFFIX="-sign.zip"
$DEBUG && ! $ROM_IS_OFFICIAL && ZIP_FILE_SUFFIX=".zip"

BUILD_DATE="$(date +%Y%m%d)"
FILE_NAME="${ROM_DISPLAY_NAME}_${BUILD_DATE}_${TARGET_CODENAME}${ZIP_FILE_SUFFIX}"
while [ -f "$OUT_DIR/$FILE_NAME" ]; do
    INCREMENTAL=$((INCREMENTAL + 1))
    FILE_NAME="${ROM_DISPLAY_NAME}_${BUILD_DATE}-${INCREMENTAL}_${TARGET_CODENAME}${ZIP_FILE_SUFFIX}"
done

export TARGET_AVB_IMAGE_PACK_DIR="$OUT_DIR/target/$TARGET_CODENAME/signed_images"
export TARGET_AVB_IMAGE_PACK_ZIP="$OUT_DIR/${FILE_NAME%.zip}-images.zip"
HEIMDALL_DIR="$OUT_DIR/${FILE_NAME%.zip}-heimdall"
ODIN_AP_DIR="$OUT_DIR/target/$TARGET_CODENAME/odin_ap"
ODIN_EXTRA_DIR="$OUT_DIR/target/$TARGET_CODENAME/odin_extra"
ODIN_EXTRA_AP_DIR="$ODIN_EXTRA_DIR/ap"
ODIN_EXTRA_CP_DIR="$ODIN_EXTRA_DIR/cp"
ODIN_EXTRA_CSC_DIR="$ODIN_EXTRA_DIR/csc"

ENSURE_SHARED_PLATFORM_SIGNING_CERTS || exit 1
PRIVATE_KEY_PATH="$(GET_PLATFORM_CERT_PK8_PATH)"
PUBLIC_KEY_PATH="$(GET_PLATFORM_CERT_X509_PATH)"

trap 'rm -rf "$TMP_DIR"' EXIT INT

# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/build_super_image.py#72
BUILD_SUPER_EMPTY()
{
    local CMD

    CMD="lpmake"
    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/build_super_image.py#75
    CMD+=" --metadata-size \"65536\""
    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/core/config.mk#1033
    CMD+=" --super-name \"super\""
    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/build_super_image.py#85
    CMD+=" --metadata-slots \"2\""
    CMD+=" --device \"super:$TARGET_SUPER_PARTITION_SIZE\""
    CMD+=" --group \"$TARGET_SUPER_GROUP_NAME:$TARGET_SUPER_GROUP_SIZE\""
    if [ -f "$TMP_DIR/system.img" ]; then
        CMD+=" --partition \"system:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/vendor.img" ]; then
        CMD+=" --partition \"vendor:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/product.img" ]; then
        CMD+=" --partition \"product:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/system_ext.img" ]; then
        CMD+=" --partition \"system_ext:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/odm.img" ]; then
        CMD+=" --partition \"odm:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/vendor_dlkm.img" ]; then
        CMD+=" --partition \"vendor_dlkm:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/odm_dlkm.img" ]; then
        CMD+=" --partition \"odm_dlkm:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    if [ -f "$TMP_DIR/system_dlkm.img" ]; then
        CMD+=" --partition \"system_dlkm:readonly:0:$TARGET_SUPER_GROUP_NAME\""
    fi
    CMD+=" --output \"$TMP_DIR/unsparse_super_empty.img\""

    EVAL "$CMD" || exit 1
}

BUILD_ODIN_SUPER_IMAGE()
{
    local OUTPUT_FILE="$1"
    local IMAGE_DIR="$2"
    local CMD
    local PARTITION
    local PARTITION_SIZE
    local SUPER_PARTITIONS="system vendor product system_ext odm vendor_dlkm odm_dlkm system_dlkm"

    CMD="lpmake"
    CMD+=" --metadata-size \"65536\""
    CMD+=" --super-name \"super\""
    CMD+=" --metadata-slots \"2\""
    if [ -f "$FW_DIR/$TARGET_FIRMWARE_PATH/os_partitions_metadata.txt" ] && \
            grep -q "^virtual_ab=true$" "$FW_DIR/$TARGET_FIRMWARE_PATH/os_partitions_metadata.txt"; then
        CMD+=" --virtual-ab"
    fi
    CMD+=" --device \"super:$TARGET_SUPER_PARTITION_SIZE\""
    CMD+=" --group \"$TARGET_SUPER_GROUP_NAME:$TARGET_SUPER_GROUP_SIZE\""

    for PARTITION in $SUPER_PARTITIONS; do
        if [ -f "$IMAGE_DIR/$PARTITION.img" ]; then
            PARTITION_SIZE="$(GET_IMAGE_SIZE "$IMAGE_DIR/$PARTITION.img")"
            CMD+=" --partition \"$PARTITION:readonly:$PARTITION_SIZE:$TARGET_SUPER_GROUP_NAME\""
            CMD+=" --image \"$PARTITION=$IMAGE_DIR/$PARTITION.img\""
        fi
    done

    CMD+=" --sparse"
    CMD+=" --output \"$OUTPUT_FILE\""

    EVAL "$CMD" || exit 1
    SIGN_SUPER_IMAGE_IF_REQUIRED "$OUTPUT_FILE"
}

GET_KV_VALUE()
{
    local KEY="$1"
    local LIST="$2"
    local ENTRY
    local VALUE=""

    for ENTRY in $LIST; do
        [ "${ENTRY%%=*}" = "$KEY" ] && VALUE="${ENTRY#*=}"
    done

    [ -n "$VALUE" ] && echo "$VALUE"
}

GET_AVB_IMAGE_PACK_MANIFEST()
{
    local MANIFEST="$TARGET_AVB_IMAGE_PACK_DIR/avb_manifest.txt"

    [ -f "$MANIFEST" ] && echo "$MANIFEST"
}

LIST_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS()
{
    local MANIFEST=""

    MANIFEST="$(GET_AVB_IMAGE_PACK_MANIFEST || true)"
    [ -n "$MANIFEST" ] || return 0

    grep '^firmware_component=' "$MANIFEST" | cut -d '=' -f 2-
}

SHOULD_PACKAGE_BOOTLOADER_COMPONENTS_IN_AP()
{
    if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_BOOTLOADER && $TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE; then
        return 1
    fi

    return 0
}

IS_BOOTLOADER_COMPONENT()
{
    local PARTITION="$1"
    local COMPONENT_FILE="$2"
    local COMPONENT
    local COMPONENT_PARTITION
    local BOOTLOADER_COMPONENTS="sboot.bin ldfw.img tzsw.img keystorage.bin harx.bin ssp.img tzar.img uh.bin vbmeta_samsung.img up_param.bin"

    for COMPONENT in $BOOTLOADER_COMPONENTS; do
        COMPONENT_PARTITION="${COMPONENT%.*}"
        if [ "$COMPONENT_FILE" = "$COMPONENT" ] || [ "$PARTITION" = "$COMPONENT_PARTITION" ]; then
            return 0
        fi
    done

    return 1
}

COPY_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS_TO_TMP()
{
    local ENTRY=""
    local PARTITION=""
    local COMPONENT_FILE=""

    $TARGET_ENABLE_CUSTOM_AVB || return 0

    while IFS= read -r ENTRY; do
        [ -n "$ENTRY" ] || continue
        PARTITION="${ENTRY%%=*}"
        COMPONENT_FILE="${ENTRY#*=}"
        [ "$PARTITION" = "bootloader" ] && continue
        [ -f "$TARGET_AVB_IMAGE_PACK_DIR/$COMPONENT_FILE" ] || continue

        LOG "- Copying AVB firmware component for zip: $PARTITION ($COMPONENT_FILE)"
        cp -fa "$TARGET_AVB_IMAGE_PACK_DIR/$COMPONENT_FILE" "$TMP_DIR/$COMPONENT_FILE"
    done < <(LIST_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS)
}

RESOLVE_TARGET_RECOVERY_IMAGE_PATH()
{
    if [ -n "$TARGET_RECOVERY_IMAGE_PATH" ] && [ "$TARGET_RECOVERY_IMAGE_PATH" != "none" ]; then
        [ -f "$TARGET_RECOVERY_IMAGE_PATH" ] && echo "$TARGET_RECOVERY_IMAGE_PATH" && return 0
        LOGW "Configured recovery image does not exist: $TARGET_RECOVERY_IMAGE_PATH"
        return 1
    fi

    return 1
}

COPY_TARGET_RECOVERY_IMAGE_TO_TMP()
{
    local RECOVERY_IMAGE=""

    RECOVERY_IMAGE="$(RESOLVE_TARGET_RECOVERY_IMAGE_PATH || true)"
    [ -n "$RECOVERY_IMAGE" ] || return 0

    mkdir -p "$WORK_DIR/kernel"
    if [[ "$RECOVERY_IMAGE" == *.zip ]]; then
        LOG "- Extracting target recovery.img from ${RECOVERY_IMAGE//$SRC_DIR\//}"
        unzip -p "$RECOVERY_IMAGE" "*.img" > "$WORK_DIR/kernel/recovery.img" || exit 1
    else
        LOG "- Copying target recovery.img from ${RECOVERY_IMAGE//$SRC_DIR\//}"
        cp -fa "$RECOVERY_IMAGE" "$WORK_DIR/kernel/recovery.img"
    fi
    cp -fa "$WORK_DIR/kernel/recovery.img" "$TMP_DIR/recovery.img"
}

RUN_SAMSUNG_AP_IMAGE_SIGNING()
{
    local IMAGE_DIR="$1"
    local PHASE="$2"

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    $TARGET_SAMSUNG_SIGN_AP_IMAGES || return 0

    if [ "$TARGET_PLATFORM" != "exynos990" ]; then
        LOGW "Samsung AP image signing is only enabled for TARGET_PLATFORM=exynos990; skipping $TARGET_PLATFORM"
        return 0
    fi

    python3 "$SRC_DIR/scripts/samsung_signing/sign_ap_images.py" \
        --images-dir "$IMAGE_DIR" \
        --keys-dir "$TARGET_SAMSUNG_SIGNING_KEY_DIR" \
        --phase "$PHASE" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --rollback "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" || exit 1
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

SIGN_DOWNLOAD_ODIN_COMPONENT()
{
    local IMAGE="$1"
    local REQUIRED="$2"
    local KEY_TYPE=""
    local PRIVATE_KEY=""
    local SIGNED_TMP
    local VERIFY_ARGS

    $TARGET_ENABLE_SAMSUNG_SIGNING || return 0
    if [ "$TARGET_PLATFORM" != "exynos990" ]; then
        LOGW "Samsung download Odin firmware signing is only enabled for TARGET_PLATFORM=exynos990; skipping $(basename "$IMAGE")"
        return 0
    fi

    KEY_TYPE="$(GET_DOWNLOAD_SIGNATURE_KEY_TYPE "$IMAGE" || true)"
    if [ -z "$KEY_TYPE" ]; then
        if [ "$REQUIRED" = "true" ]; then
            LOGE "$(basename "$IMAGE") has no recognizable sparse download signature layout"
            exit 1
        fi
        LOGW "$(basename "$IMAGE") has no recognizable sparse download signature layout; keeping stock"
        return 0
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
        -r "$TARGET_SAMSUNG_SIGNING_ROLLBACK_INDEX" || exit 1
    mv -f "$SIGNED_TMP" "$IMAGE"

    VERIFY_ARGS="$(SAMSUNG_VERIFY_KEY_ARGS)"
    # shellcheck disable=SC2086
    python3 "$SRC_DIR/scripts/samsung_signing/download_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        $VERIFY_ARGS || exit 1
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
    local AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-$SRC_DIR/platform_external_avb-master/avbtool.py}"
    local AVB_PYTHON="${TARGET_AVBTOOL_PYTHON:-python3}"

    [ "$AVBTOOL_PATH" != "none" ] || AVBTOOL_PATH="$SRC_DIR/platform_external_avb-master/avbtool.py"
    [ "$AVB_PYTHON" != "none" ] || AVB_PYTHON="python3"
    [ -f "$AVBTOOL_PATH" ] || return 0

    "$AVB_PYTHON" - "$AVBTOOL_PATH" "$IMAGE" <<'PY'
import importlib.util
import sys

avbtool_path, image_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location('crecker_avbtool', avbtool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

avb = module.Avb()
image = module.ImageHandler(image_path, read_only=True)
try:
    footer, header, descriptors, _ = avb._parse_image(image)
except Exception:
    raise SystemExit(0)

if footer is None:
    raise SystemExit(0)

for desc in descriptors:
    if isinstance(desc, module.AvbHashtreeDescriptor):
        do_not_use_ab = int(bool(desc.flags & desc.FLAGS_DO_NOT_USE_AB))
        check_at_most_once = int(bool(desc.flags & desc.FLAGS_CHECK_AT_MOST_ONCE))
        do_not_generate_fec = int(desc.fec_num_roots == 0)
        print('\t'.join([
            'hashtree',
            desc.partition_name,
            desc.hash_algorithm,
            str(header.rollback_index),
            str(header.rollback_index_location),
            str(do_not_use_ab),
            str(check_at_most_once),
            str(do_not_generate_fec),
        ]))
        raise SystemExit(0)
    if isinstance(desc, module.AvbHashDescriptor):
        do_not_use_ab = int(bool(desc.flags & (1 << 0)))
        print('\t'.join([
            'hash',
            desc.partition_name,
            desc.hash_algorithm,
            str(header.rollback_index),
            str(header.rollback_index_location),
            str(do_not_use_ab),
            '0',
            '0',
        ]))
        raise SystemExit(0)
PY
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
    local AVBTOOL_PATH="${TARGET_AVBTOOL_PATH:-$SRC_DIR/platform_external_avb-master/avbtool.py}"
    local AVB_PYTHON="${TARGET_AVBTOOL_PYTHON:-python3}"
    local AVB_KEY_PATH="${TARGET_AVB_KEY_PATH:-$SRC_DIR/security/avb/creckerrom_avb_private.pem}"
    local AVB_ALGORITHM="${TARGET_AVB_ALGORITHM:-SHA256_RSA4096}"
    local CMD=()

    $TARGET_ENABLE_CUSTOM_AVB || return 0
    [ -f "$IMAGE" ] || return 0

    [ -n "$AVB_INFO" ] || AVB_INFO="$(GET_ODIN_COMPONENT_AVB_INFO "$IMAGE" || true)"
    [ -n "$AVB_INFO" ] || return 0

    IFS=$'\t' read -r KIND PARTITION_NAME HASH_ALGORITHM ROLLBACK_INDEX ROLLBACK_INDEX_LOCATION \
        DO_NOT_USE_AB CHECK_AT_MOST_ONCE DO_NOT_GENERATE_FEC <<< "$AVB_INFO"
    ROLLBACK_INDEX="${TARGET_AVB_ROLLBACK_INDEX:-23}"

    [ "$AVBTOOL_PATH" != "none" ] || AVBTOOL_PATH="$SRC_DIR/platform_external_avb-master/avbtool.py"
    [ "$AVB_PYTHON" != "none" ] || AVB_PYTHON="python3"
    [ -f "$AVBTOOL_PATH" ] || {
        LOGE "AVB tool not found for Odin firmware component signing: $AVBTOOL_PATH"
        exit 1
    }
    [ -f "$AVB_KEY_PATH" ] || {
        LOGE "AVB key not found for Odin firmware component signing: $AVB_KEY_PATH"
        exit 1
    }

    PARTITION_SIZE="$(GET_IMAGE_SIZE "$IMAGE")" || exit 1
    [ -n "$HASH_ALGORITHM" ] || HASH_ALGORITHM="${TARGET_AVB_HASH_ALGORITHM:-sha256}"

    LOG "- AVB-signing Odin firmware component $ENTRY_NAME after Samsung signing ($KIND, partition=$PARTITION_NAME)"
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

    "$AVB_PYTHON" "$AVBTOOL_PATH" "${CMD[@]}" || exit 1
    "$AVB_PYTHON" "$AVBTOOL_PATH" verify_image --image "$IMAGE" --key "$AVB_KEY_PATH" || exit 1
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
        AVB_INFO="$(GET_ODIN_COMPONENT_AVB_INFO "$OUTPUT_PATH" || true)"
        case "$SIGN_KIND" in
            "download")
                SIGN_DOWNLOAD_ODIN_COMPONENT "$OUTPUT_PATH" "$REQUIRED_SIGN"
                ;;
            "stage2")
                SIGN_STAGE2_ODIN_COMPONENT "$OUTPUT_PATH" "$SIGN_STAGE" "$REQUIRED_SIGN"
                ;;
        esac
        SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED "$OUTPUT_PATH" "$ENTRY_NAME" "$AVB_INFO"
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
    AVB_INFO="$(GET_ODIN_COMPONENT_AVB_INFO "$OUTPUT_PATH" || true)"

    case "$SIGN_KIND" in
        "download")
            SIGN_DOWNLOAD_ODIN_COMPONENT "$OUTPUT_PATH" "$REQUIRED_SIGN"
            ;;
        "stage2")
            SIGN_STAGE2_ODIN_COMPONENT "$OUTPUT_PATH" "$SIGN_STAGE" "$REQUIRED_SIGN"
            ;;
    esac
    SIGN_AVB_ODIN_COMPONENT_IF_REQUIRED "$OUTPUT_PATH" "$ENTRY_NAME" "$AVB_INFO"
}

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
    local BL_TAR_PATH="$OUT_DIR/BL_${FILE_NAME%.zip}.tar"
    local BL_TAR_MD5="$OUT_DIR/BL_${FILE_NAME%.zip}.tar.md5"
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
    local TAR_PATH="$OUT_DIR/${PACKAGE_PREFIX}_${FILE_NAME%.zip}.tar"
    local TAR_MD5="$OUT_DIR/${PACKAGE_PREFIX}_${FILE_NAME%.zip}.tar.md5"
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

IS_HEIMDALL_DYNAMIC_PARTITION_IMAGE()
{
    case "$1" in
        system.img | vendor.img | product.img | system_ext.img | odm.img | \
            vendor_dlkm.img | odm_dlkm.img | system_dlkm.img)
            return 0
            ;;
    esac

    return 1
}

COPY_HEIMDALL_IMAGES_FROM_DIR()
{
    local SOURCE_DIR="$1"
    local ENTRY
    local FILE_NAME

    [ -d "$SOURCE_DIR" ] || return 0

    while IFS= read -r ENTRY; do
        FILE_NAME="$(basename "$ENTRY")"
        if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ] && \
                IS_HEIMDALL_DYNAMIC_PARTITION_IMAGE "$FILE_NAME"; then
            continue
        fi
        if [ -f "$HEIMDALL_DIR/$FILE_NAME" ]; then
            continue
        fi

        LOG "- Copying Heimdall image $FILE_NAME"
        cp -fa "$ENTRY" "$HEIMDALL_DIR/$FILE_NAME"
    done < <(find "$SOURCE_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "*.bin" \) | sort)
}

BUILD_HEIMDALL_PACKAGE()
{
    local IMAGE_DIR="$TMP_DIR"

    if $TARGET_ENABLE_CUSTOM_AVB; then
        IMAGE_DIR="$TARGET_AVB_IMAGE_PACK_DIR"
    fi

    [ -d "$HEIMDALL_DIR" ] && rm -rf "$HEIMDALL_DIR"
    mkdir -p "$HEIMDALL_DIR"

    if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
        if [ -f "$ODIN_AP_DIR/super.img" ]; then
            LOG "- Copying Heimdall image super.img"
            cp -fa "$ODIN_AP_DIR/super.img" "$HEIMDALL_DIR/super.img"
        else
            LOG "- Building super.img for Heimdall"
            BUILD_ODIN_SUPER_IMAGE "$HEIMDALL_DIR/super.img" "$IMAGE_DIR"
        fi
    fi

    COPY_HEIMDALL_IMAGES_FROM_DIR "$TARGET_SAMSUNG_SIGNED_BOOTLOADER_DIR"
    COPY_HEIMDALL_IMAGES_FROM_DIR "$ODIN_EXTRA_AP_DIR"
    COPY_HEIMDALL_IMAGES_FROM_DIR "$ODIN_EXTRA_CP_DIR"
    COPY_HEIMDALL_IMAGES_FROM_DIR "$ODIN_EXTRA_CSC_DIR"
    COPY_HEIMDALL_IMAGES_FROM_DIR "$IMAGE_DIR"
    [ "$IMAGE_DIR" != "$TMP_DIR" ] && COPY_HEIMDALL_IMAGES_FROM_DIR "$TMP_DIR"

    cp -fa "$SRC_DIR/prebuilts/extras/flash_heimdall.sh" "$HEIMDALL_DIR/flash_all.sh"
    chmod 0755 "$HEIMDALL_DIR/flash_all.sh"

    find "$HEIMDALL_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "*.bin" \) -print -quit | grep -q . || {
        LOGE "No Heimdall flash folder contents were generated"
        exit 1
    }
}

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
# ]

[ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR/META-INF/com/google/android"
cp -a "$SRC_DIR/prebuilts/bootable/deprecated-ota/updater" "$TMP_DIR/META-INF/com/google/android/update-binary"
mkdir -p "$TMP_DIR/scripts"
cp -a "$SRC_DIR/prebuilts/extras/cleanup.sh" "$TMP_DIR/scripts/cleanup.sh"

LOG_STEP_IN "- Building OS partitions"
while IFS= read -r f; do
    PARTITION=$(basename "$f")
    IS_VALID_PARTITION_NAME "$PARTITION" || continue

    (
        LOG_STEP_IN "- Building $PARTITION.img"
        if [[ "$PARTITION" == "prism" || "$PARTITION" == "optics" ]]; then
            FILESYSTEM_TYPE="ext4"
        else
            FILESYSTEM_TYPE="$TARGET_OS_FILE_SYSTEM"
        fi
        "$SRC_DIR/scripts/build_fs_image.sh" "$FILESYSTEM_TYPE" \
            -o "$TMP_DIR/$PARTITION.img" -S \
            "$WORK_DIR/$PARTITION" "$WORK_DIR/configs/file_context-$PARTITION" "$WORK_DIR/configs/fs_config-$PARTITION" || exit 1
        LOG_STEP_OUT
    ) &
done < <(find "$WORK_DIR" -maxdepth 1 -type d)
LOG_STEP_OUT

# shellcheck disable=SC2046
wait $(jobs -p) || exit 1

if [ -d "$WORK_DIR/kernel" ]; then
    while IFS= read -r f; do
        IMG="$(basename "$f")"
        LOG "- Copying $IMG"
        cp -fa "$WORK_DIR/kernel/$IMG" "$TMP_DIR/$IMG"
    done < <(find "$WORK_DIR/kernel" -maxdepth 1 -type f -name "*.img")
fi

if [ -f "$WORK_DIR/up_param.bin" ]; then
    LOG "- Copying up_param.bin"
    cp -fa "$WORK_DIR/up_param.bin" "$TMP_DIR/up_param.bin"
fi

COPY_TARGET_RECOVERY_IMAGE_TO_TMP

if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_AP_IMAGES; then
    LOG_STEP_IN "- Samsung-signing AP images before AVB"
    RUN_SAMSUNG_AP_IMAGE_SIGNING "$TMP_DIR" "before-avb"
    LOG_STEP_OUT
fi

if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_BOOTLOADER; then
    LOG_STEP_IN "- Samsung-signing bootloader"
    RUN_SAMSUNG_BOOTLOADER_SIGNING
    LOG_STEP_OUT
fi

if $TARGET_ENABLE_CUSTOM_AVB; then
    LOG_STEP_IN "- Signing AVB images"
    "$SRC_DIR/scripts/internal/sign_avb_images.sh" "$TMP_DIR" || exit 1
    LOG_STEP_OUT
    if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_SIGN_AP_IMAGES; then
        LOG_STEP_IN "- Samsung-signing vbmeta after AVB"
        RUN_SAMSUNG_AP_IMAGE_SIGNING "$TARGET_AVB_IMAGE_PACK_DIR" "after-avb"
        [ -f "$TARGET_AVB_IMAGE_PACK_DIR/vbmeta.img" ] && cp -fa "$TARGET_AVB_IMAGE_PACK_DIR/vbmeta.img" "$TMP_DIR/vbmeta.img"
        LOG_STEP_OUT
    fi
    COPY_AVB_IMAGE_PACK_FIRMWARE_COMPONENTS_TO_TMP
fi

if $TARGET_BUILD_ODIN_PACKAGE || $TARGET_BUILD_HEIMDALL_PACKAGE; then
    LOG_STEP_IN "- Preparing extra firmware images"
    PREPARE_ODIN_EXTRA_FIRMWARE_IMAGES
    LOG_STEP_OUT
fi

if $TARGET_BUILD_ODIN_PACKAGE; then
    if $TARGET_ENABLE_SAMSUNG_SIGNING && $TARGET_SAMSUNG_BUILD_ODIN_BL_PACKAGE; then
        LOG_STEP_IN "- Building Odin BL package"
        BUILD_ODIN_BL_PACKAGE
        LOG_STEP_OUT
    fi

    LOG_STEP_IN "- Building Odin AP package"
    BUILD_ODIN_AP_PACKAGE
    LOG_STEP_OUT

    LOG_STEP_IN "- Building Odin CP package"
    BUILD_ODIN_CP_PACKAGE
    LOG_STEP_OUT

    LOG_STEP_IN "- Building Odin CSC package"
    BUILD_ODIN_CSC_PACKAGE
    LOG_STEP_OUT
fi

if $TARGET_BUILD_HEIMDALL_PACKAGE; then
    LOG_STEP_IN "- Building Heimdall flash folder"
    BUILD_HEIMDALL_PACKAGE
    LOG_STEP_OUT
fi

if ! $TARGET_BUILD_FLASHABLE_ZIP; then
    exit 0
fi

if [ "$TARGET_SUPER_PARTITION_SIZE" -ne 0 ]; then
    LOG "- Building unsparse_super_empty.img"
    BUILD_SUPER_EMPTY

    LOG "- Generating dynamic_partitions_op_list"
    GENERATE_OP_LIST
fi

BROTLI_QUALITY="$TARGET_BROTLI_QUALITY"
$DEBUG && BROTLI_QUALITY=0

while IFS= read -r f; do
    PARTITION="$(basename "$f")"
    IS_VALID_PARTITION_NAME "$PARTITION" || continue
    [ -f "$TMP_DIR/$PARTITION.img" ] || continue

    (
        LOG "- Converting $PARTITION.img to $PARTITION.new.dat"
        EVAL "img2sdat -o \"$TMP_DIR\" \"$TMP_DIR/$PARTITION.img\"" || exit 1
        rm -f "$TMP_DIR/$PARTITION.img"

        LOG "- Compressing $PARTITION.new.dat"
        # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/common.py#3585
        EVAL "brotli --quality=\"$BROTLI_QUALITY\" --output=\"$TMP_DIR/$PARTITION.new.dat.br\" \"$TMP_DIR/$PARTITION.new.dat\"" || exit 1
        rm -f "$TMP_DIR/$PARTITION.new.dat"
    ) &
done < <(find "$WORK_DIR" -maxdepth 1 -type d)

# shellcheck disable=SC2046
wait $(jobs -p) || exit 1

LOG "- Generating updater-script"
GENERATE_UPDATER_SCRIPT

LOG "- Generating build_info.txt"
GENERATE_BUILD_INFO

LOG "- Generating OTA metadata"
GENERATE_OTA_METADATA

LOG "- Creating zip"
EVAL "rm -f \"$OUT_DIR/rom.zip\"" || exit 1
pushd "$TMP_DIR" > /dev/null

# 1. Compressed files (everything except zips, special dat files, META-INF)
find . -type f ! -name "*.new.dat.br" ! -name "*.patch.dat" > compressed.txt

# 2. Stored files (special dat files + META-INF folder)
find . -type f \( -name "*.new.dat.br" -o -name "*.patch.dat" -o -name "META-INF" \) > stored.txt
META_INF="./META-INF"

# Add batches
EVAL "7z a -tzip -mx=$TARGET_ROM_ZIP_COMPRESSION_LEVEL -mmt=$(nproc --all) \"$TMP_DIR/rom.zip\" @\"compressed.txt\""
EVAL "7z a -tzip -mx=0 -mmt=$(nproc --all) \"$TMP_DIR/rom.zip\" @\"stored.txt\" \"$META_INF\""

if ! $DEBUG; then
    LOG "- Signing zip"
    EVAL "signapk -w \"$PUBLIC_KEY_PATH\" \"$PRIVATE_KEY_PATH\" \"$TMP_DIR/rom.zip\" \"$OUT_DIR/$FILE_NAME\"" || exit 1
    rm -f "$TMP_DIR/rom.zip"
else
    mv -f "$TMP_DIR/rom.zip" "$OUT_DIR/$FILE_NAME"
fi

popd > /dev/null

exit 0
