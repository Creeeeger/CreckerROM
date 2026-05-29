LIST_HAS_ITEM()
{
    local ITEM="$1"
    local LIST="$2"
    local ENTRY

    for ENTRY in $LIST; do
        [ "$ENTRY" = "$ITEM" ] && return 0
    done

    return 1
}

APPEND_UNIQUE()
{
    local VAR_NAME="$1"
    local ITEM="$2"
    local CURRENT

    eval "CURRENT=\${$VAR_NAME}"
    LIST_HAS_ITEM "$ITEM" "$CURRENT" && return 0

    if [ -n "$CURRENT" ]; then
        eval "$VAR_NAME=\"\$CURRENT \$ITEM\""
    else
        eval "$VAR_NAME=\"\$ITEM\""
    fi
}

REMOVE_ITEM()
{
    local VAR_NAME="$1"
    local ITEM="$2"
    local CURRENT
    local UPDATED=""
    local ENTRY

    eval "CURRENT=\${$VAR_NAME}"

    for ENTRY in $CURRENT; do
        [ "$ENTRY" = "$ITEM" ] && continue

        if [ -n "$UPDATED" ]; then
            UPDATED="$UPDATED $ENTRY"
        else
            UPDATED="$ENTRY"
        fi
    done

    eval "$VAR_NAME=\"\$UPDATED\""
}

REMOVE_KV_ITEM()
{
    local VAR_NAME="$1"
    local KEY="$2"
    local CURRENT
    local UPDATED=""
    local ENTRY

    eval "CURRENT=\${$VAR_NAME}"

    for ENTRY in $CURRENT; do
        [ "${ENTRY%%=*}" = "$KEY" ] && continue

        if [ -n "$UPDATED" ]; then
            UPDATED="$UPDATED $ENTRY"
        else
            UPDATED="$ENTRY"
        fi
    done

    eval "$VAR_NAME=\"\$UPDATED\""
}

GET_KV_VALUE()
{
    local KEY="$1"
    local LIST="$2"
    local ENTRY
    local VALUE=""

    for ENTRY in $LIST; do
        [ "${ENTRY%%=*}" = "$KEY" ] && VALUE="${ENTRY#*=}"
    done

    [ -n "$VALUE" ] && echo "$VALUE"
}
