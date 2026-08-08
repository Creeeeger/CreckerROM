#!/usr/bin/env bash
#
# Build an old Exynos990 firmware with current custom AVB/Samsung signatures.
# This path intentionally does not create or modify a normal ROM work directory.
#

set -e

[ "${TARGET_BUILD_MODE:-normal}" = "rollback" ] || {
    echo "build_rollback_firmware.sh requires TARGET_BUILD_MODE=rollback" >&2
    exit 1
}

source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

source "$SRC_DIR/scripts/internal/rollback/extraction.sh" || exit 1
source "$SRC_DIR/scripts/internal/rollback/signing.sh" || exit 1
source "$SRC_DIR/scripts/internal/rollback/assembly.sh" || exit 1
source "$SRC_DIR/scripts/internal/rollback/firmware_build.sh" || exit 1
exit 0
