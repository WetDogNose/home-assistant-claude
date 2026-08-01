#!/bin/bash

# ha-validate — Validate Home Assistant YAML configuration via Core API
# Usage: ha-validate [--backup <file>] [--safe-edit <file>]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-validate — Validate Home Assistant configuration

Usage:
  ha-validate                    Run configuration check against Home Assistant Core
  ha-validate --backup <file>    Snapshot <file> to <file>.bak BEFORE editing it
  ha-validate --safe-edit <file> Run check, restore <file> from <file>.bak if invalid

Safe-edit is a two-step flow, because a backup taken after an edit only
preserves the broken version:

  ha-validate --backup /config/automations.yaml     # before you edit
  <edit the file>
  ha-validate --safe-edit /config/automations.yaml  # after you edit

Examples:
  ha-validate
  ha-validate --backup /config/automations.yaml
  ha-validate --safe-edit /config/automations.yaml
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
    exit 0
fi

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "Error: SUPERVISOR_TOKEN environment variable is not set." >&2
    echo "ha-validate must be run inside the Home Assistant add-on environment." >&2
    exit 1
fi

check_config() {
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        "http://supervisor/core/api/config/core/check_config")

    local status errors
    status=$(echo "$response" | jq -r '.result // "error"')
    errors=$(echo "$response" | jq -r '.errors // empty')

    if [ "$status" = "valid" ]; then
        echo "✅ Home Assistant configuration is VALID."
        return 0
    else
        echo "❌ Home Assistant configuration is INVALID!" >&2
        if [ -n "$errors" ] && [ "$errors" != "null" ]; then
            echo "Errors:" >&2
            echo "$errors" >&2
        else
            echo "Full response: $response" >&2
        fi
        return 1
    fi
}

case "${1:-}" in
    --backup)
        FILE="${2:-}"
        if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
            echo "Error: Specify a valid file path for --backup" >&2
            exit 1
        fi
        cp "$FILE" "${FILE}.bak"
        echo "Created pre-edit backup: ${FILE}.bak"
        echo "Run 'ha-validate --safe-edit ${FILE}' after editing to verify and roll back on failure."
        ;;

    --safe-edit)
        FILE="${2:-}"
        if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
            echo "Error: Specify a valid file path for --safe-edit" >&2
            exit 1
        fi

        BACKUP="${FILE}.bak"

        # Deliberately does NOT create the backup here. This runs AFTER the
        # edit, so snapshotting now captures the broken file, and "restoring"
        # it copies the same broken content back -- a rollback that silently
        # does nothing. A usable rollback needs a pre-edit snapshot, which is
        # what --backup is for.
        if [ ! -f "$BACKUP" ]; then
            echo "Warning: no pre-edit backup at ${BACKUP}; cannot roll back." >&2
            echo "Run 'ha-validate --backup ${FILE}' BEFORE editing next time." >&2
            echo "Validating anyway..." >&2
            check_config
            exit $?
        fi

        if check_config; then
            echo "Edit verified clean. Backup kept at ${BACKUP}."
        else
            echo "Restoring ${FILE} from ${BACKUP} due to validation errors..." >&2
            cp "$BACKUP" "$FILE"
            echo "Restored ${FILE} from the pre-edit backup." >&2
            exit 1
        fi
        ;;

    "")
        check_config
        ;;

    *)
        echo "Error: unknown option '$1'" >&2
        echo "" >&2
        show_help >&2
        exit 1
        ;;
esac
