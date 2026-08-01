#!/bin/bash

# ha-snapshot — Capture a camera snapshot from Home Assistant
# Usage: ha-snapshot <camera_entity_id> [output_file]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-snapshot — Capture a camera snapshot from Home Assistant

Usage:
  ha-snapshot <camera_entity_id> [output_file]

Examples:
  ha-snapshot camera.front_door
  ha-snapshot camera.garage /config/www/snapshots/garage.jpg

Output defaults to /config/www/snapshots/<camera_entity_id>.jpg
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
    show_help
    exit 0
fi

ENTITY_ID="$1"
# Ensure entity ID starts with camera. or add camera. prefix if omitted
if [[ "$ENTITY_ID" != camera.* ]]; then
    ENTITY_ID="camera.${ENTITY_ID}"
fi

DEFAULT_DIR="/config/www/snapshots"
DEFAULT_FILE="${DEFAULT_DIR}/${ENTITY_ID#camera.}.jpg"
OUTPUT_FILE="${2:-$DEFAULT_FILE}"

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "Error: SUPERVISOR_TOKEN environment variable is not set." >&2
    echo "ha-snapshot must be run inside the Home Assistant add-on environment." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "Capturing snapshot from ${ENTITY_ID}..."

HTTP_CODE=$(curl -s -w "%{http_code}" -o "$OUTPUT_FILE" \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    "http://supervisor/core/api/camera_proxy/${ENTITY_ID}")

if [ "$HTTP_CODE" -eq 200 ] && [ -s "$OUTPUT_FILE" ]; then
    echo "Snapshot saved to: ${OUTPUT_FILE}"
    echo "Size: $(du -h "$OUTPUT_FILE" | cut -f1)"
else
    echo "Failed to capture snapshot (HTTP ${HTTP_CODE})." >&2
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
    exit 1
fi
