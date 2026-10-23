# The UI7 camera keeps the legacy SmartScan JNI entry points. Pair those with
# the target firmware's scan engine and ONNX model, rather than 9945 NPU code.
LOG_STEP_IN "- Restoring target document scan engine"

SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_CAMERA_DOCUMENTSCAN_SOLUTIONS" \
    "AI_DEWARPING,SHADOW_REMOVAL" || return 1

for scan_arch in lib lib64
do
    for scan_lib in \
        libDocRectifyWrapper.camera.samsung.so \
        libDeepDocRectify.camera.samsung.so \
        libSimpleDocRectify.camera.samsung.so \
        libDocShadowRemoval.arcsoft.so \
        libRectify.camera.samsung.so
    do
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/$scan_arch/$scan_lib" \
            0 0 644 "u:object_r:system_lib_file:s0" || return 1
    done

    # These are document-specific extensions, not Gallery's separate MIDAS
    # engines. Remove stale files too when reapplying to an existing workdir.
    for scan_lib in \
        libDocDeblur.camera.samsung.so \
        libDocDeblur.enhanceX.samsung.so \
        libDocObjectRemoval.camera.samsung.so \
        libDocObjectRemoval.enhanceX.samsung.so \
        libDocColorEnhance.camera.samsung.so \
        libDocColorEnhance_Auto.camera.samsung.so
    do
        if [ -e "$WORK_DIR/system/system/$scan_arch/$scan_lib" ] || \
                [ -L "$WORK_DIR/system/system/$scan_arch/$scan_lib" ]; then
            DELETE_FROM_WORK_DIR "system" "system/$scan_arch/$scan_lib" || return 1
        fi
    done
done

# DeepDocRectify loads this bridge dynamically; keep its options ABI paired.
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
    "system/lib64/libDLInterface_aidl.camera.samsung.so" \
    0 0 644 "u:object_r:system_lib_file:s0" || return 1
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
    "system/saiv/image_understanding/db/smartscan_rectifier/deep_dewarp_cnn.sni" || return 1
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "vendor" \
    "saiv/image_understanding/db/smartscan_rectifier/deep_dewarp_cnn.onnx" || return 1

for scan_assets in \
    etc/saiv/image_understanding/db/doc_rectifier \
    etc/midas_enhancedocumentscan \
    saiv/image_understanding/db/aig_document_detector \
    saiv/image_understanding/db/aig_document_classifier
do
    if [ -e "$WORK_DIR/vendor/$scan_assets" ] || [ -L "$WORK_DIR/vendor/$scan_assets" ]; then
        DELETE_FROM_WORK_DIR "vendor" "$scan_assets" || return 1
    fi
done

unset scan_arch scan_lib scan_assets
LOG_STEP_OUT
