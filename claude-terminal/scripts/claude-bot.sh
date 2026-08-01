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
  claude-bot setup                       Interactive webhook setup guide

Examples:
  claude-bot forward "Turn off all lights"
  claude-bot status
EOF
}

BOT_CONFIG="${BOT_CONFIG:-/data/claude-bot-config.json}"

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

    echo "Forwarding prompt to Automation API..."
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${token}" \
        -d "$(jq -n --arg p "$prompt" '{prompt: $p}')" \
        "http://127.0.0.1:8128/api/query" | jq .
}

case "${1:-}" in
    status)
        cmd_status
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
