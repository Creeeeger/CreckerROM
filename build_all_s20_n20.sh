#!/usr/bin/env bash
# Copyright (C) 2026 Creeeeger

set -Ee -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRINT_USAGE()
{
    echo "Usage: $0 [--stock] [--ksu|--no-ksu]" >&2
    echo " --stock : Use stock recovery from each target AP firmware (default: TWRP)" >&2
    echo " --ksu : Include KernelSU in the kernel and preload its manager app (default)" >&2
    echo " --no-ksu : Disable KernelSU in the kernel and omit its manager app" >&2
}

BUILD_OPTIONS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --stock|--ksu|--no-ksu)
            BUILD_OPTIONS+=("$1")
            ;;
        -h|--help)
            PRINT_USAGE
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            PRINT_USAGE
            exit 1
            ;;
    esac
    shift
done

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
            "${BUILD_OPTIONS[@]}" \
            "$TARGET"

        export TARGET_BUILD_HEIMDALL_PACKAGE=false
        ./scripts/make_rom.sh
    )
done

printf '\nAll requested S20/Note20 Odin builds completed successfully.\n'
