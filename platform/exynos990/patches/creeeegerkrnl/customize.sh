# [
CREEEEGER_KERNEL_REPO="https://github.com/Creeeeger/exynos990Kernel"
CREEEEGER_KERNEL_REPO="${CREEEEGER_KERNEL_REPO%/}"
CREEEEGER_KERNEL_STABLE_BRANCH="OneUI7_8_stable"

HAS_LTE_DTBO()
{
    case "$TARGET_CODENAME" in
        x1s|y2s|c1s|c2s)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

BUILD_KERNEL()
{
    local PARENT
    PARENT="$(pwd)"

    cd "$KERNEL_TMP_DIR" || return 1

    if ! EVAL "./build.sh -m ${TARGET_CODENAME} -k y -r n"; then
        cd "$PARENT" || true
        return 1
    fi

    if HAS_LTE_DTBO; then
        if ! EVAL "./build.sh -m ${TARGET_CODENAME}lte -k n -r n -d y"; then
            cd "$PARENT" || true
            return 1
        fi
    fi

    cd "$PARENT" || return 1
}

SELECT_KERNEL_REMOTE_BRANCH()
{
    local BRANCH

    if [ "${TARGET_SAMSUNG_ENABLE_KVM:-false}" = "true" ]; then
        while IFS= read -r BRANCH; do
            case "$(printf '%s' "$BRANCH" | tr '[:upper:]' '[:lower:]')" in
                *kvm*)
                    printf '%s\n' "$BRANCH"
                    return 0
                    ;;
            esac
        done < <(
            git -C "$KERNEL_TMP_DIR" for-each-ref \
                --sort=refname \
                --format='%(refname:strip=3)' \
                refs/remotes/origin \
                | sed '/^HEAD$/d'
        )
        return 1
    fi

    git -C "$KERNEL_TMP_DIR" show-ref --verify --quiet \
        "refs/remotes/origin/$CREEEEGER_KERNEL_STABLE_BRANCH" || return 1
    printf '%s\n' "$CREEEEGER_KERNEL_STABLE_BRANCH"
}

SAFE_PULL_CHANGES()
{
    local BASE
    local LOCAL
    local REMOTE
    local REMOTE_BRANCH

    # Repair repositories previously cloned with --single-branch as well as
    # configuring fresh clones: every origin branch must have a remote ref.
    EVAL "git -C \"$KERNEL_TMP_DIR\" remote set-branches origin '*'" || return 1
    EVAL "git -C \"$KERNEL_TMP_DIR\" fetch origin --prune --recurse-submodules=on-demand" || return 1

    if ! REMOTE_BRANCH="$(SELECT_KERNEL_REMOTE_BRANCH)"; then
        if [ "${TARGET_SAMSUNG_ENABLE_KVM:-false}" = "true" ]; then
            ABORT "No origin branch containing 'kvm' was found in the Creeeeger kernel repository."
            return 1
        fi
        ABORT "Stable kernel branch origin/$CREEEEGER_KERNEL_STABLE_BRANCH was not found."
        return 1
    fi

    if [ -z "$REMOTE_BRANCH" ] || \
        ! git check-ref-format --branch "$REMOTE_BRANCH" >/dev/null 2>&1 || \
        ! git -C "$KERNEL_TMP_DIR" show-ref --verify --quiet "refs/remotes/origin/$REMOTE_BRANCH"; then
        ABORT "Selected kernel branch is invalid or missing on origin: ${REMOTE_BRANCH:-<empty>}"
        return 1
    fi

    LOG "- Selecting kernel branch: $REMOTE_BRANCH"
    if git -C "$KERNEL_TMP_DIR" show-ref --verify --quiet "refs/heads/$REMOTE_BRANCH"; then
        EVAL "git -C \"$KERNEL_TMP_DIR\" switch \"$REMOTE_BRANCH\"" || return 1
    else
        EVAL "git -C \"$KERNEL_TMP_DIR\" switch --track -c \"$REMOTE_BRANCH\" \"origin/$REMOTE_BRANCH\"" || return 1
    fi

    LOCAL="$(git -C "$KERNEL_TMP_DIR" rev-parse HEAD)" || return 1
    REMOTE="$(git -C "$KERNEL_TMP_DIR" rev-parse "origin/$REMOTE_BRANCH")" || return 1
    if ! BASE="$(git -C "$KERNEL_TMP_DIR" merge-base HEAD "origin/$REMOTE_BRANCH")"; then
        ABORT "Selected kernel branch and origin/$REMOTE_BRANCH have no common history."
        return 1
    fi

    # Now we have three cases that we need to take care of.
    if [[ "$LOCAL" == "$REMOTE" ]]; then
        LOG "- Selected kernel branch is up-to-date with origin."
    elif [[ "$LOCAL" == "$BASE" ]]; then
        LOG "- Fast-forward possible. Updating selected kernel branch."
        EVAL "git -C \"$KERNEL_TMP_DIR\" merge --ff-only \"origin/$REMOTE_BRANCH\"" || return 1
    elif [[ "$REMOTE" == "$BASE" ]]; then
        LOGW "- Local branch is ahead of remote. Not doing anything."
    else
        ABORT "Remote history has diverged (possible force-push)."
        return 1
    fi

    # The selected branch may pin different submodule commits than the branch
    # used for the initial clone.
    EVAL "git -C \"$KERNEL_TMP_DIR\" submodule sync --recursive" || return 1
    EVAL "git -C \"$KERNEL_TMP_DIR\" submodule update --init --recursive" || return 1
}

REPLACE_KERNEL_BINARIES()
{
    local KERNEL_TMP_DIR="$KERNEL_TMP_DIR-$TARGET_PLATFORM"
    [[ ! -d "$KERNEL_TMP_DIR" ]] && mkdir -p "$KERNEL_TMP_DIR"

    if [[ -d "$KERNEL_TMP_DIR/.git" ]]; then
        local CURRENT_URL

        CURRENT_URL="$(git -C "$KERNEL_TMP_DIR" remote get-url origin 2>/dev/null || true)"
        CURRENT_URL="${CURRENT_URL%/}"
        if [ "$CURRENT_URL" != "$CREEEEGER_KERNEL_REPO" ] && [ "$CURRENT_URL" != "$CREEEEGER_KERNEL_REPO.git" ]; then
            LOGW "- Kernel repo URL mismatch, recloning"
            rm -rf "$KERNEL_TMP_DIR"
        fi
    fi

    if [[ ! -d "$KERNEL_TMP_DIR/.git" ]]; then
        LOG "- Cloning Creeeeger kernel repo"
        EVAL "git clone --recurse-submodules \"$CREEEEGER_KERNEL_REPO\" \"$KERNEL_TMP_DIR\"" || return 1
    else
        LOG "- Existing Creeeeger kernel repo found"
    fi

    if ! SAFE_PULL_CHANGES; then
        ABORT "Could not select or update the required Kernel branch. If you hold local changes, commit or stash them first."
        return 1
    fi

    LOG "- Running the kernel build script."
    BUILD_KERNEL || return 1

    for i in "boot" "dtbo"; do
        [[ -f "$WORK_DIR/kernel/$i.img" ]] && rm -f "$WORK_DIR/kernel/$i.img"
        mv -f "$KERNEL_TMP_DIR/build/out/$TARGET_CODENAME/$i.img" "$WORK_DIR/kernel/$i.img"
    done

    # And now for the LTE DTBOs
    if [[ "$TARGET_CODENAME" != "r8s" ]] && [[ "$TARGET_CODENAME" != "z3s" ]]; then
	    mv -f "$KERNEL_TMP_DIR/build/out/${TARGET_CODENAME}lte/dtbo.img" "$WORK_DIR/kernel/dtbo_lte.img"
    fi
}
# ]

REPLACE_KERNEL_BINARIES
