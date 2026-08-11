#!/usr/bin/env bash

set -Ee -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILDS=(
    "G780F r8s"
    "G980F x1s"
    "G981B x1s"
    "G985F y2s"
    "G986B y2s"
    "G988B z3s"
    "N980F c1s"
    "N981B c1s"
    "N985F c2s"
    "N986B c2s"
)

for BUILD in "${BUILDS[@]}"; do
    read -r MODEL TARGET <<< "$BUILD"
    printf '\n========== %s (%s) ==========\n' "$MODEL" "$TARGET"

    (
        source ./buildenv.sh \
            --official \
            --encrypt \
            --no-debloat \
            --avb \
            --avb-model "$MODEL" \
            "$TARGET"

        export TARGET_BUILD_HEIMDALL_PACKAGE=false
        ./scripts/make_rom.sh
    )
done

printf '\nAll requested S20/Note20 Odin builds completed successfully.\n'
