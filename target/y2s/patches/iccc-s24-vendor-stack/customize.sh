SKIPUNZIP=1

ICCC_SOURCE="SM-S721B/EUX"

ADD_TO_WORK_DIR "$ICCC_SOURCE" "vendor" "bin/hw/vendor.samsung.hardware.tlc.iccc@1.0-service"
ADD_TO_WORK_DIR "$ICCC_SOURCE" "vendor" "lib64/vendor.samsung.hardware.tlc.iccc@1.0.so"
ADD_TO_WORK_DIR "$ICCC_SOURCE" "vendor" "lib64/vendor.samsung.hardware.tlc.iccc@1.0-impl.so"
ADD_TO_WORK_DIR "$ICCC_SOURCE" "vendor" "lib64/libtlc_comm_iccc.so"
ADD_TO_WORK_DIR "$ICCC_SOURCE" "vendor" "lib64/libtlc_direct_comm_iccc.so"
