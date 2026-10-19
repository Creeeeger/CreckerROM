# Copyright (C) 2026 Creeeeger
# SPDX-License-Identifier: GPL-3.0-or-later

# RUN_KERNEL_BUILD <model> <ksu y|n> [build.sh options]
RUN_KERNEL_BUILD()
(
    local MODEL="$1"
    local KSU_OPTION="$2"
    local MODEL_CONFIG
    local CONFIG_BACKUP
    shift 2

    cd "$KERNEL_TMP_DIR" || return 1

    if [ "$KSU_OPTION" = "n" ]; then
        MODEL_CONFIG="arch/arm64/configs/$MODEL.config"
        [ -f "$MODEL_CONFIG" ] || {
            LOGE "Missing kernel model config: $MODEL_CONFIG"
            return 1
        }
        CONFIG_BACKUP="$(mktemp)" || return 1
        cp -p "$MODEL_CONFIG" "$CONFIG_BACKUP" || { rm -f "$CONFIG_BACKUP"; return 1; }
        trap 'cp -p "$CONFIG_BACKUP" "$MODEL_CONFIG"; rm -f "$CONFIG_BACKUP"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

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
    EVAL "$CMD" || return 1

    if [ "$KSU_OPTION" = "n" ]; then
        [ -s out/.config ] || {
            LOGE "Kernel build did not produce out/.config"
            return 1
        }
        if grep -Eq '^CONFIG_KSU=[ym]$' out/.config; then
            LOGE "KernelSU is still enabled in the compiled kernel config"
            return 1
        fi
    fi
)
