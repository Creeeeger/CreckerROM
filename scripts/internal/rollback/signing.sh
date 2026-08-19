SAMSUNG_PRIVATE_KEY()
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

GET_DOWNLOAD_KEY_TYPE()
{
    local IMAGE="$1"

    python3 - "$SRC_DIR" "$IMAGE" <<'PY'
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts/samsung_signing")
from download_signature_common import parse_download_signature_layout
try:
    print(parse_download_signature_layout(sys.argv[2]).key_type)
except ValueError:
    raise SystemExit(1)
PY
}

GET_STAGE2_KEY_TYPE()
{
    local IMAGE="$1"
    local STAGE="$2"

    python3 - "$SRC_DIR" "$IMAGE" "$STAGE" <<'PY'
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts/samsung_signing")
from stage2_common import normalize_stage, parse_stage2_footer, read_file, stage2_footer_candidate_sizes
stage = normalize_stage(sys.argv[3])
data = read_file(sys.argv[2])
sizes = stage2_footer_candidate_sizes(stage, data)
if not sizes:
    raise SystemExit(1)
print(parse_stage2_footer(data, sizes[0]).key_type)
PY
}

VERIFY_STAGE2_IMAGE()
{
    local IMAGE="$1"
    local STAGE="$2"

    [ -f "$IMAGE" ] || return 0
    python3 "$SRC_DIR/scripts/samsung_signing/stage2_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --stage "$STAGE" \
        -i "$IMAGE" \
        --tee-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_tee_pubkey.bin" \
        --ree-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_ree_pubkey.bin" \
        --stage3-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage3_pubkey.bin"
}

VERIFY_SAMSUNG_DOWNLOAD()
{
    python3 "$SRC_DIR/scripts/samsung_signing/download_verify_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$1" \
        --tee-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_tee_pubkey.bin" \
        --ree-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage2_ree_pubkey.bin" \
        --stage3-pub-key "$TARGET_SAMSUNG_SIGNING_KEY_DIR/crecker_stage3_pubkey.bin"
}

PREPARE_DOWNLOAD_IMAGE_FOR_AVB()
{
    local IMAGE="$1"
    local PREPARED_TMP="$IMAGE.download-avb.tmp"

    [ -f "$IMAGE" ] || return 0
    LOG "- Preparing $(basename "$IMAGE") Samsung rollback metadata before AVB"
    rm -f "$PREPARED_TMP"
    # The stock image is its own layout/default reference.  The preparation
    # pass updates the download header plus both SignerInfo RP fields and
    # leaves FullHashSig zero, which is the exact representation LK writes and
    # AVB must authenticate.
    python3 "$SRC_DIR/scripts/samsung_signing/download_prepare_avb_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        -o "$PREPARED_TMP" \
        --reference "$IMAGE" \
        -r "$ROLLBACK_INDEX"
    mv -f "$PREPARED_TMP" "$IMAGE"
}

SIGN_DOWNLOAD_IMAGE()
{
    local IMAGE="$1"
    local REQUIRED="${2:-true}"
    local KEY_TYPE
    local PRIVATE_KEY
    local SIGNED_TMP="$IMAGE.signed.tmp"

    [ -f "$IMAGE" ] || return 0
    KEY_TYPE="$(GET_DOWNLOAD_KEY_TYPE "$IMAGE" || true)"
    if [ -z "$KEY_TYPE" ]; then
        if $REQUIRED; then
            LOGE "$(basename "$IMAGE") has no recognizable Samsung download signature"
            exit 1
        fi
        LOGW "$(basename "$IMAGE") has no recognizable Samsung download signature; keeping it unchanged"
        return 0
    fi

    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY "$KEY_TYPE")"
    LOG "- Samsung-signing $(basename "$IMAGE") download signature"
    rm -f "$SIGNED_TMP"
    python3 "$SRC_DIR/scripts/samsung_signing/download_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$IMAGE" \
        -o "$SIGNED_TMP" \
        -k "$PRIVATE_KEY" \
        -r "$ROLLBACK_INDEX" \
        --key-type "$KEY_TYPE"
    mv -f "$SIGNED_TMP" "$IMAGE"
    VERIFY_SAMSUNG_DOWNLOAD "$IMAGE"
}

SIGN_STAGE2_IMAGE()
{
    local IMAGE="$1"
    local STAGE="$2"
    local REQUIRED="${3:-true}"
    local KEY_TYPE
    local PRIVATE_KEY

    [ -f "$IMAGE" ] || return 0
    KEY_TYPE="$(GET_STAGE2_KEY_TYPE "$IMAGE" "$STAGE" || true)"
    if [ -z "$KEY_TYPE" ]; then
        if $REQUIRED; then
            LOGE "$(basename "$IMAGE") has no recognizable Samsung Stage-2 footer"
            exit 1
        fi
        LOGW "$(basename "$IMAGE") has no recognizable Samsung Stage-2 footer; keeping it unchanged"
        return 0
    fi

    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY "$KEY_TYPE")"
    LOG "- Samsung-signing $(basename "$IMAGE") as $STAGE"
    python3 "$SRC_DIR/scripts/samsung_signing/stage2_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        --stage "$STAGE" \
        -i "$IMAGE" \
        -o "$IMAGE" \
        -k "$PRIVATE_KEY" \
        -r "$ROLLBACK_INDEX" \
        --key-type "$KEY_TYPE"
    VERIFY_STAGE2_IMAGE "$IMAGE" "$STAGE"
}

SIGN_SUPER_IMAGE()
{
    local KEY_TYPE
    local PRIVATE_KEY

    # The rebuilt super image borrows key_type and SignerInfo defaults from the
    # old signed super reference so Odin/Heimdall see the expected format.
    KEY_TYPE="$(GET_DOWNLOAD_KEY_TYPE "$SUPER_REFERENCE")"
    PRIVATE_KEY="$(SAMSUNG_PRIVATE_KEY "$KEY_TYPE")"
    python3 "$SRC_DIR/scripts/samsung_signing/download_sign_tool.py" \
        --soc "$TARGET_SAMSUNG_SIGNING_SOC" \
        -i "$SUPER_UNSIGNED" \
        -o "$SUPER_OUTPUT" \
        -k "$PRIVATE_KEY" \
        -r "$ROLLBACK_INDEX" \
        --key-type "$KEY_TYPE" \
        --super \
        --super-reference "$SUPER_REFERENCE"
    VERIFY_SAMSUNG_DOWNLOAD "$SUPER_OUTPUT"
}
