#!/bin/bash

# claude-login-notifier — background daemon that watches the Claude tmux
# session for OAuth authorization URLs and automatically raises a Home
# Assistant persistent notification with a clickable Markdown link.
#
# Runs in the background inside the container alongside ttyd/tmux.

set -u

STATE_DIR="/run/claude-terminal"
LAST_URL_FILE="${STATE_DIR}/last_notified_url"
NOTIFIED_FLAG="${STATE_DIR}/notification_active"

mkdir -p "$STATE_DIR"

is_authenticated() {
    local config_dir="${ANTHROPIC_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude}"
    local cred
    for cred in "$HOME/.claude/.credentials.json" \
                "$config_dir/.credentials.json" "$config_dir/credentials.json"; do
        [ -f "$cred" ] || continue
        local expires_at
        expires_at=$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred" 2>/dev/null)
        if [ -n "$expires_at" ] && [ "$expires_at" -gt "$(( $(date +%s) * 1000 ))" ] 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

dismiss_notification() {
    [ -f "$NOTIFIED_FLAG" ] || return 0
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        curl -fsS -m 5 -o /dev/null \
            -X POST \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"notification_id": "claude_terminal_login"}' \
            "http://supervisor/core/api/services/persistent_notification/dismiss" \
            2>/dev/null || true
    fi
    rm -f "$NOTIFIED_FLAG" "$LAST_URL_FILE"
}

while true; do
    # If authenticated, clear any lingering sign-in notification and sleep longer
    if is_authenticated; then
        dismiss_notification
        sleep 10
        continue
    fi

    # Capture pane output from the tmux session
    url=$(tmux capture-pane -p -J -t claude -S -500 2>/dev/null \
        | grep -oE "https://(claude\.(com|ai)|console\.anthropic\.com|platform\.claude\.com)[^[:space:]\"'\`)<>]*" \
        | tail -1)

    if [ -n "$url" ]; then
        last_url=""
        [ -f "$LAST_URL_FILE" ] && last_url=$(cat "$LAST_URL_FILE" 2>/dev/null)

        if [ "$url" != "$last_url" ]; then
            if [ -x /usr/local/bin/ha-notify ]; then
                msg="Open this URL to authorize Claude Code, then return to the terminal and paste the code:

[👉 Authorize Claude Code](${url})

Or copy the URL:
${url}"
                if /usr/local/bin/ha-notify \
                    "Claude Terminal Sign-In Required" \
                    "$msg" \
                    "claude_terminal_login"; then
                    echo "$url" > "$LAST_URL_FILE"
                    touch "$NOTIFIED_FLAG"
                fi
            fi
        fi
    fi

    sleep 3
done
