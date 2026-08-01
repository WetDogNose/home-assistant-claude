#!/bin/bash

# ha-tts — Send text-to-speech announcement to Home Assistant media player
# Usage: ha-tts "<message>" [media_player_entity_id]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-tts — Send text-to-speech announcement to Home Assistant

Usage:
  ha-tts "<message>" [media_player_entity_id]

Examples:
  ha-tts "Front door motion detected"
  ha-tts "Dinner is ready!" media_player.kitchen_speaker
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
    show_help
    exit 0
fi

MESSAGE="$1"
TARGET_PLAYER="${2:-media_player.living_room_speaker}"

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "Error: SUPERVISOR_TOKEN environment variable is not set." >&2
    echo "ha-tts must be run inside the Home Assistant add-on environment." >&2
    exit 1
fi

echo "Sending TTS announcement to ${TARGET_PLAYER}..."

# Try notify / tts service via HA API
PAYLOAD=$(jq -n \
    --arg msg "$MESSAGE" \
    --arg player "$TARGET_PLAYER" \
    '{entity_id: $player, message: $msg}')

HTTP_CODE=$(curl -s -w "%{http_code}" -o /dev/null \
    -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "http://supervisor/core/api/services/tts/google_translate_say")

if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
    echo "TTS announcement sent successfully."
else
    # Fallback to notify service
    FALLBACK_PAYLOAD=$(jq -n --arg msg "$MESSAGE" '{message: $msg}')
    curl -s -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$FALLBACK_PAYLOAD" \
        "http://supervisor/core/api/services/notify/notify" >/dev/null || true
    echo "Sent via HA notification service (TTS HTTP status ${HTTP_CODE})."
fi
