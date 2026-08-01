#!/bin/bash

# claude-bot — Remote Messaging Bot Gateway for Telegram, Matrix, or Discord
# Usage: claude-bot [status|forward "<message>"|setup]

set -euo pipefail

show_help() {
    cat << 'EOF'
claude-bot — Remote Messaging Bot Gateway for Claude Terminal

Usage:
  claude-bot status                      Show configured messaging bots
  claude-bot forward "<prompt>"          Forward a message to Automation API
  claude-bot setup                       Show the messaging setup guide

Examples:
  claude-bot forward "Turn off all lights"
  claude-bot status
EOF
}

BOT_CONFIG="${BOT_CONFIG:-/data/claude-bot-config.json}"
OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"

# The Automation API listens on `automation_api_port`, which is not always the
# 8128 default. Hardcoding it meant `forward` failed for anyone who changed the
# option.
api_port() {
    local port=""
    if [ -f "$OPTIONS_FILE" ]; then
        port=$(jq -r '.automation_api_port // empty' "$OPTIONS_FILE" 2>/dev/null || echo "")
    fi
    case "$port" in
        ''|*[!0-9]*) echo "8128" ;;
        *)           echo "$port" ;;
    esac
}

init_config() {
    if [ ! -f "$BOT_CONFIG" ]; then
        mkdir -p "$(dirname "$BOT_CONFIG")"
        echo '{"enabled": false, "platform": "telegram", "webhook_url": ""}' > "$BOT_CONFIG"
    fi
}

cmd_status() {
    init_config
    echo "=== Claude Remote Messaging Bot Status ==="
    jq . "$BOT_CONFIG"
    echo "Automation API endpoint: http://127.0.0.1:$(api_port)/api/prompt"
}

cmd_setup() {
    init_config
    cat << EOF
=== Claude Remote Messaging Bot Setup ===

claude-bot forwards prompts into the Claude Terminal Automation API. The
messaging platform itself is wired up on the Home Assistant side, because that
is where the Telegram / Matrix / Discord integrations live.

1. Add the integration in Home Assistant:
     Settings -> Devices & Services -> Add Integration
     (Telegram bot, Matrix, or Discord)

2. Create an automation that reacts to an incoming message and calls the
   Automation API. The shipped "Claude Terminal Task Trigger" blueprint does
   exactly this; see the add-on documentation for the rest_command it needs.

3. Or forward from this terminal directly:
     claude-bot forward "Turn off all lights"

Local settings file: ${BOT_CONFIG}
Automation API:      http://127.0.0.1:$(api_port)/api/prompt
API token:           /data/automation_api_token
EOF
}

cmd_forward() {
    local prompt="${1:-}"
    if [ -z "$prompt" ]; then
        echo "Error: Specify prompt to forward." >&2
        exit 1
    fi

    local token_file="/data/automation_api_token"
    local token=""
    if [ -f "$token_file" ]; then
        token=$(cat "$token_file")
    fi

    if [ -z "$token" ]; then
        echo "Error: no Automation API token in ${token_file}." >&2
        echo "The API server writes one at start-up; check enable_automation_api is on." >&2
        exit 1
    fi

    echo "Forwarding prompt to Automation API..."
    # /api/prompt is the path claude-api-server.py actually serves; /api/query
    # was never routed and always answered 404.
    local response
    if ! response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${token}" \
        -d "$(jq -n --arg p "$prompt" '{prompt: $p}')" \
        "http://127.0.0.1:$(api_port)/api/prompt"); then
        echo "Error: could not reach the Automation API." >&2
        exit 1
    fi

    # A non-JSON error page must not abort the script through `set -e`.
    echo "$response" | jq . 2>/dev/null || echo "$response"
}

case "${1:-}" in
    status)
        cmd_status
        ;;
    setup)
        cmd_setup
        ;;
    forward)
        cmd_forward "${2:-}"
        ;;
    -h|--help)
        show_help
        ;;
    *)
        show_help
        ;;
esac
