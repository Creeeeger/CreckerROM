# Preserve the installed device's boot-control state and encryption keys in
# update packages, including when an earlier full build left staged images.
SHOULD_SKIP_UPDATE_IMAGE()
{
    [ "${TARGET_BUILD_UPDATE:-false}" = "true" ] || return 1

    local ENTRY
    local PARTITION
    for ENTRY in "$@"; do
        PARTITION="${ENTRY##*/}"
        PARTITION="${PARTITION%.*}"
        case "$PARTITION" in
            misc | metadata | userdata)
                return 0
                ;;
        esac
    done

    return 1
}
