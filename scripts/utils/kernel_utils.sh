# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

# SET_KERNEL_CONFIG_VERSION <config> <localversion>
SET_KERNEL_CONFIG_VERSION()
{
    sed -i '/^CONFIG_LOCALVERSION=/d; /^CONFIG_LOCALVERSION_AUTO=/d; /^# CONFIG_LOCALVERSION_AUTO is not set/d' "$1" || return 1
    printf '\nCONFIG_LOCALVERSION="%s"\n# CONFIG_LOCALVERSION_AUTO is not set\n' "$2" >> "$1"
}

# RUN_KERNEL_BUILD <model> <ksu y|n> [build.sh options]
# KERNEL_LOCALVERSION and KERNEL_BASE_CONFIG optionally pin the kernel version.
RUN_KERNEL_BUILD()
(
    local MODEL="$1"
    local KSU_OPTION="$2"
    local MODEL_CONFIG="arch/arm64/configs/$MODEL.config"
    local CONFIG_BACKUP_DIR
    local KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:-}"
    local KERNEL_BASE_CONFIG="${KERNEL_BASE_CONFIG:-}"
    shift 2

    cd "$KERNEL_TMP_DIR" || return 1

    if [ "$KSU_OPTION" = "n" ] || [ -n "$KERNEL_LOCALVERSION" ]; then
        [ -f "$MODEL_CONFIG" ] || {
            LOGE "Missing kernel model config: $MODEL_CONFIG"
            return 1
        }
        CONFIG_BACKUP_DIR="$(mktemp -d)" || return 1
        trap '
            if [ -f "$CONFIG_BACKUP_DIR/model" ]; then
                cp -p "$CONFIG_BACKUP_DIR/model" "$MODEL_CONFIG"
            fi
            if [ -f "$CONFIG_BACKUP_DIR/base" ]; then
                cp -p "$CONFIG_BACKUP_DIR/base" "$KERNEL_BASE_CONFIG"
            fi
            rm -rf "$CONFIG_BACKUP_DIR"
        ' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cp -p "$MODEL_CONFIG" "$CONFIG_BACKUP_DIR/model" || return 1
    fi

    if [ -n "$KERNEL_LOCALVERSION" ]; then
        [ -f "$KERNEL_BASE_CONFIG" ] || {
            LOGE "Missing kernel base config: $KERNEL_BASE_CONFIG"
            return 1
        }
        cp -p "$KERNEL_BASE_CONFIG" "$CONFIG_BACKUP_DIR/base" || return 1
        # build.sh also reads the base defconfig to name its kernel ZIP.
        SET_KERNEL_CONFIG_VERSION "$KERNEL_BASE_CONFIG" "$KERNEL_LOCALVERSION" || return 1
        SET_KERNEL_CONFIG_VERSION "$MODEL_CONFIG" "$KERNEL_LOCALVERSION" || return 1
    fi

    if [ "$KSU_OPTION" = "n" ]; then
        # Some base defconfigs already enable KSU. The model fragment must
        # explicitly disable it even when build.sh is called with -k n.
        sed -i '/^CONFIG_KSU=/d; /^# CONFIG_KSU is not set/d' "$MODEL_CONFIG" || return 1
        printf '\n# CONFIG_KSU is not set\n' >> "$MODEL_CONFIG" || return 1
    fi

    local CMD
    printf -v CMD './build.sh -m %q -k %q' "$MODEL" "$KSU_OPTION"
    local ARG
    for ARG in "$@"; do
        printf -v CMD '%s %q' "$CMD" "$ARG"
    done
    if [ -n "$KERNEL_LOCALVERSION" ]; then
        CMD="LOCALVERSION='' $CMD"
    fi
    EVAL "$CMD" || return 1

    if [ "$KSU_OPTION" = "n" ] || [ -n "$KERNEL_LOCALVERSION" ]; then
        [ -s out/.config ] || {
            LOGE "Kernel build did not produce out/.config"
            return 1
        }
    fi
    if [ -n "$KERNEL_LOCALVERSION" ] && \
            ! grep -Fqx "CONFIG_LOCALVERSION=\"$KERNEL_LOCALVERSION\"" out/.config; then
        LOGE "Compiled kernel version does not match $KERNEL_LOCALVERSION"
        return 1
    fi
    if [ "$KSU_OPTION" = "n" ]; then
        if grep -Eq '^CONFIG_KSU=[ym]$' out/.config; then
            LOGE "KernelSU is still enabled in the compiled kernel config"
            return 1
        fi
    fi
)
