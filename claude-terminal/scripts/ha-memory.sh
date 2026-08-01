#!/bin/bash

# ha-memory — Search Home Assistant state transition and event history
# Usage: ha-memory <search_query_or_entity_id> [hours_back]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-memory — Search Home Assistant historical state transitions

Usage:
  ha-memory <entity_id_or_filter> [hours_back]

Examples:
  ha-memory lock.front_door 24
  ha-memory climate.living_room 48
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
    show_help
    exit 0
fi

FILTER="$1"
HOURS="${2:-24}"

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "Error: SUPERVISOR_TOKEN environment variable is not set." >&2
    echo "ha-memory must be run inside the Home Assistant add-on environment." >&2
    exit 1
fi

# Calculate start time ISO-8601
START_TIME=$(date -u -v"-${HOURS}H" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "${HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

echo "Searching history for '${FILTER}' (past ${HOURS} hours)..."

URL="http://supervisor/core/api/history/period"
if [ -n "$START_TIME" ]; then
    URL="${URL}/${START_TIME}"
fi

HISTORY=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${URL}?filter_entity_id=${FILTER}")

if [ "$(echo "$HISTORY" | jq 'type' 2>/dev/null)" = "array" ]; then
    echo "$HISTORY" | jq -r '.[][] | "[\(.last_updated)] \(.entity_id) -> \(.state)"' | head -n 30
else
    echo "No history matches found for ${FILTER}."
fi
