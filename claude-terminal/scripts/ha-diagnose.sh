#!/bin/bash

# ha-diagnose — One-command Home Assistant & Claude Terminal diagnostic report
# Usage: ha-diagnose

set -euo pipefail

ADDON_VER=$(cat /opt/scripts/addon-version 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "# Home Assistant & Claude Terminal Diagnostic Report"
echo "Generated: ${TIMESTAMP}"
echo "Add-on Version: ${ADDON_VER}"
echo ""

echo "## 1. System & Container Environment"
echo "- Home: ${HOME:-unknown}"
echo "- User: $(whoami 2>/dev/null || echo root)"

if command -v free >/dev/null 2>&1; then
    echo "- Memory: $(free -h | awk '/Mem:/ {print $3 "/" $2}')"
else
    echo "- Memory: N/A (non-Linux OS)"
fi

if [ -d "/config" ]; then
    if command -v df >/dev/null 2>&1; then
        echo "- Disk /config: $(df -h /config | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')"
    else
        echo "- Disk /config: N/A"
    fi
else
    echo "- Disk /config: N/A (/config not mounted)"
fi
echo ""

echo "## 2. Home Assistant Config Validation"
if command -v ha-validate >/dev/null 2>&1; then
    ha-validate || true
else
    echo "ha-validate utility not found."
fi
echo ""

echo "## 3. Entity Domain Summary"
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    STATES=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "http://supervisor/core/api/states" || echo "")
    if [ -n "$STATES" ] && [ "$(echo "$STATES" | jq 'type' 2>/dev/null)" = "array" ]; then
        echo "$STATES" | jq -r 'group_by(.entity_id | split(".")[0]) | .[] | "- **" + (.[0].entity_id | split(".")[0]) + "**: " + (length | tostring) + " entities"'
    else
        echo "Unable to fetch states array from Supervisor API."
    fi
else
    echo "SUPERVISOR_TOKEN not set; skipping entity summary."
fi
echo ""

echo "## 4. Recent Home Assistant Log Errors"
if [ -f "/config/home-assistant.log" ]; then
    ERR_LINES=$(grep -i "ERROR\|CRITICAL\|WARNING" /config/home-assistant.log | tail -n 10 || true)
    if [ -n "$ERR_LINES" ]; then
        echo '```text'
        echo "$ERR_LINES"
        echo '```'
    else
        echo "No recent errors found in /config/home-assistant.log."
    fi
else
    echo "/config/home-assistant.log file not accessible."
fi
echo ""

echo "## 5. Automation API & Background Daemon Status"
if pgrep -f "claude-api-server" >/dev/null 2>&1; then
    echo "- Automation API: Running"
else
    echo "- Automation API: Stopped"
fi
if pgrep -f "claude-cron daemon" >/dev/null 2>&1; then
    echo "- Claude Cron Daemon: Running"
else
    echo "- Claude Cron Daemon: Stopped"
fi
echo ""
