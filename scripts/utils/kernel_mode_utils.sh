# Validate mode selection before generating configs or changing kernel branches.
VALIDATE_KERNEL_MODE_SELECTION()
{
    local SECURE_KERNEL="${1:-false}"
    local KVM="${2:-false}"
    local BUILD_MODE="${3:-normal}"
    local PLATFORM="${4:-}"
    local LOCAL_BRANCH="${5:-}"

    if [[ "$SECURE_KERNEL" != "true" && "$SECURE_KERNEL" != "false" ]]; then
        printf 'Invalid secure kernel flag: %s (expected: true|false)\n' "$SECURE_KERNEL" >&2
        return 1
    fi
    if [[ "$SECURE_KERNEL" == "true" ]]; then
        if [[ "$KVM" == "true" ]]; then
            echo "--secureKernel and --kvm cannot be used together" >&2
            return 1
        fi
        if [[ "$BUILD_MODE" != "normal" ]]; then
            echo "--secureKernel cannot be used with --rollback or another firmware build mode" >&2
            return 1
        fi
        if [[ -n "$PLATFORM" && "$PLATFORM" != "exynos990" ]]; then
            echo "--secureKernel supports Exynos990 targets only" >&2
            return 1
        fi
        if [[ -n "$LOCAL_BRANCH" && "$LOCAL_BRANCH" != "Samsung_security" ]]; then
            printf -- '--secureKernel conflicts with KERNEL_BRANCH=%s; unset KERNEL_BRANCH or use Samsung_security\n' "$LOCAL_BRANCH" >&2
            return 1
        fi
    fi
    if [[ "$KVM" == "true" && "$LOCAL_BRANCH" == "Samsung_security" ]]; then
        echo "KERNEL_BRANCH=Samsung_security cannot be used with --kvm" >&2
        return 1
    fi
}
