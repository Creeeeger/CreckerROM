# [
CREEEEGER_KERNEL_REPO="https://github.com/Creeeeger/exynos990Kernel"
CREEEEGER_KERNEL_REPO="${CREEEEGER_KERNEL_REPO%/}"

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

    cd "$KERNEL_TMP_DIR"

    EVAL "./build.sh -m ${TARGET_CODENAME} -k y -r n"

    if HAS_LTE_DTBO; then
        EVAL "./build.sh -m ${TARGET_CODENAME}lte -k n -r n -d y"
    fi

    cd "$PARENT"
}

SAFE_PULL_CHANGES()
{
    set -eo pipefail

    local PARENT
    local REMOTE_BRANCH

    PARENT="$(pwd)"

    cd "$KERNEL_TMP_DIR"

    EVAL "git fetch origin"

    REMOTE_BRANCH="$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
    REMOTE_BRANCH="${REMOTE_BRANCH#refs/remotes/origin/}"
    [ "$REMOTE_BRANCH" ] || REMOTE_BRANCH="OneUI7_8"

    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse "origin/$REMOTE_BRANCH")
    BASE=$(git merge-base @ "origin/$REMOTE_BRANCH")

    # Now we have three cases that we need to take care of.
    if [[ "$LOCAL" == "$REMOTE" ]]; then
        LOG "- Local branch is up-to-date with remote."
    elif [[ "$LOCAL" == "$BASE" ]]; then
        LOG "- Fast-forward possible. Pulling."
        EVAL "git pull --ff-only"
    elif [[ "$REMOTE" == "$BASE" ]]; then
        LOGW "- Local branch is ahead of remote. Not doing anything."
    else
        cd "$PARENT"
        ABORT "Remote history has diverged (possible force-push)."
    fi

    cd "$PARENT"
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
        else
            LOG "- Existing git repo found, trying to pull latest changes"
            if ! SAFE_PULL_CHANGES; then
                ABORT "Could not pull latest Kernel changes. If you hold local changes, please rebase to the new base. If not, cleaning the kernel_tmp_dir should suffice."
            fi
        fi
    fi

    if [[ ! -d "$KERNEL_TMP_DIR/.git" ]]; then
        LOG "- Cloning Creeeeger kernel repo"
        EVAL "git clone \"$CREEEEGER_KERNEL_REPO\" --single-branch \"$KERNEL_TMP_DIR\" --recurse-submodules"
    fi

    LOG "- Running the kernel build script."
    BUILD_KERNEL

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
