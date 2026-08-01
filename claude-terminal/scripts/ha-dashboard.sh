#!/bin/bash

# ha-dashboard — Generate Lovelace Dashboard YAML by domain or area
# Usage: ha-dashboard [domain_or_area] [output_file]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-dashboard — Generate Lovelace Dashboard YAML by domain or area

Usage:
  ha-dashboard <domain_or_area> [output_file]

Examples:
  ha-dashboard climate /config/dashboards/climate.yaml
  ha-dashboard living_room /config/dashboards/living_room.yaml
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
    show_help
    exit 0
fi

TARGET="${1:-light}"
DEFAULT_OUT="/config/dashboards/${TARGET}.yaml"
OUTPUT_FILE="${2:-$DEFAULT_OUT}"

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "Error: SUPERVISOR_TOKEN environment variable is not set." >&2
    echo "ha-dashboard must be run inside the Home Assistant add-on environment." >&2
    exit 1
fi

echo "Fetching states for ${TARGET}..."
STATES=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "http://supervisor/core/api/states")

if [ "$(echo "$STATES" | jq 'type' 2>/dev/null)" != "array" ]; then
    echo "Error: Failed to fetch valid states array from Home Assistant API." >&2
    exit 1
fi

# Filter entities matching target domain or area
MATCHING_ENTITIES=$(echo "$STATES" | jq -r --arg t "$TARGET" '.[] | select((.entity_id | startswith($t + ".")) or (.attributes.area_id == $t)) | .entity_id')

if [ -z "$MATCHING_ENTITIES" ]; then
    echo "Warning: No entities matching '${TARGET}' found." >&2
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

cat << EOF > "$OUTPUT_FILE"
title: ${TARGET^} Dashboard
views:
  - title: Overview
    path: overview
    icon: mdi:home-assistant
    cards:
      - type: grid
        title: ${TARGET^} Devices
        columns: 2
        square: false
        cards:
EOF

for entity in $MATCHING_ENTITIES; do
    cat << EOF >> "$OUTPUT_FILE"
          - type: entity
            entity: ${entity}
EOF
done

echo "Dashboard YAML generated successfully at: ${OUTPUT_FILE}"
