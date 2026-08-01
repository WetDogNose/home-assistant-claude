#!/bin/bash

# ha-validate — Validate Home Assistant YAML configuration via Core API
# Usage: ha-validate [--safe-edit <file_path>]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-validate — Validate Home Assistant configuration

Usage:
  ha-validate                   Run configuration check against Home Assistant Core
  ha-validate --safe-edit <file> Backup <file> to <file>.bak, run check, restore if invalid

Examples:
  ha-validate
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

if [ "${1:-}" = "--safe-edit" ]; then
    FILE="${2:-}"
    if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
        echo "Error: Specify a valid file path for --safe-edit" >&2
        exit 1
    fi

    BACKUP="${FILE}.bak"
    cp "$FILE" "$BACKUP"
    echo "Created backup: ${BACKUP}"

    if check_config; then
        echo "Edit verified clean."
    else
        echo "Restoring ${FILE} from ${BACKUP} due to validation errors..." >&2
        cp "$BACKUP" "$FILE"
        echo "Restored original ${FILE}." >&2
        exit 1
    fi
else
    check_config
fi
