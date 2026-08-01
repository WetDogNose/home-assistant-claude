#!/bin/bash

# ha-assist — Process text queries via Home Assistant Assist conversation pipeline
# Usage: ha-assist "<prompt>"

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-assist — Process text queries via Home Assistant Assist pipeline

Usage:
  ha-assist "<prompt>"

Examples:
  ha-assist "Are all doors locked?"
  ha-assist "Turn off living room lights"
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
    show_help
    exit 0
fi

PROMPT="$1"

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "Error: SUPERVISOR_TOKEN environment variable is not set." >&2
    echo "ha-assist must be run inside the Home Assistant add-on environment." >&2
    exit 1
fi

PAYLOAD=$(jq -n --arg text "$PROMPT" '{text: $text}')

RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://supervisor/core/api/conversation/process")

SPEECH=$(echo "$RESPONSE" | jq -r '.response.speech.plain.speech // .response.speech.ssml.speech // empty' 2>/dev/null || true)

if [ -n "$SPEECH" ]; then
    echo "Assist response:"
    echo "$SPEECH"
else
    echo "Full API response:"
    echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
fi
