#!/bin/bash

# ha-mesh — Zigbee, Z-Wave & Matter mesh network and battery health scanner
# Usage: ha-mesh

set -euo pipefail

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    echo "Error: SUPERVISOR_TOKEN environment variable is not set." >&2
    echo "ha-mesh must be run inside the Home Assistant add-on environment." >&2
    exit 1
fi

echo "# Mesh Network & Device Health Report"
echo "Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo ""

STATES=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "http://supervisor/core/api/states")

if [ "$(echo "$STATES" | jq 'type' 2>/dev/null)" != "array" ]; then
    echo "Error: Unable to retrieve states from Supervisor API." >&2
    exit 1
fi

echo "## 1. Low Battery Warnings (<20%)"
LOW_BATT=$(echo "$STATES" | jq -r '.[] | select((.attributes.device_class == "battery" or (.entity_id | endswith("_battery"))) and (.state | tonumber? != null) and (.state | tonumber < 20)) | "- **" + .entity_id + "**: " + .state + "%"')

if [ -n "$LOW_BATT" ]; then
    echo "$LOW_BATT"
else
    echo "✅ No low battery devices found."
fi
echo ""

echo "## 2. Unavailable / Offline Mesh Sensors"
UNAVAIL=$(echo "$STATES" | jq -r '.[] | select(.state == "unavailable" or .state == "unknown") | "- **" + .entity_id + "** (" + (.attributes.friendly_name // "N/A") + ")"')

if [ -n "$UNAVAIL" ]; then
    echo "$UNAVAIL" | head -n 15
    TOTAL_UNAVAIL=$(echo "$UNAVAIL" | wc -l | tr -d ' ')
    if [ "$TOTAL_UNAVAIL" -gt 15 ]; then
        echo "...and $((TOTAL_UNAVAIL - 15)) more unavailable entities."
    fi
else
    echo "✅ All entities are online."
fi
echo ""

echo "## 3. Signal Quality (LQI / RSSI)"
SIGNALS=$(echo "$STATES" | jq -r '.[] | select((.attributes.lqi != null) or (.attributes.rssi != null)) | "- **" + .entity_id + "**: LQI=" + ((.attributes.lqi // "N/A") | tostring) + ", RSSI=" + ((.attributes.rssi // "N/A") | tostring) + " dBm"')

if [ -n "$SIGNALS" ]; then
    echo "$SIGNALS" | head -n 15
else
    echo "No explicit LQI/RSSI attributes detected on active entities."
fi
echo ""
