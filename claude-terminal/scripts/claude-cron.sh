#!/bin/bash

# claude-cron — Scheduled Autonomous Task Manager for Claude Terminal
# Usage: claude-cron [list|add|remove|daemon]

set -euo pipefail

CRON_FILE="${CRON_FILE:-/data/claude-cron.json}"

init_file() {
    if [ ! -f "$CRON_FILE" ]; then
        mkdir -p "$(dirname "$CRON_FILE")"
        echo '{"jobs": []}' > "$CRON_FILE"
    fi
}

show_help() {
    cat << 'EOF'
claude-cron — Scheduled Autonomous Task Manager for Claude Terminal

Usage:
  claude-cron list                           List scheduled jobs
  claude-cron add "<minutes>" "<prompt>"     Add a recurring job (interval in minutes)
  claude-cron remove <job_id>                Remove job by ID
  claude-cron daemon                         Run scheduler loop in background

Examples:
  claude-cron add "60" "Check home energy usage and report to HA notifications"
  claude-cron list
  claude-cron remove 1
EOF
}

cmd_list() {
    init_file
    echo "=== Claude Terminal Scheduled Jobs ==="
    jq -r '.jobs[] | "[\(.id)] Every \(.interval_min)m — Prompt: \(.prompt) (Last: \(.last_run // "never"))"' "$CRON_FILE"
}

cmd_add() {
    init_file
    local interval="${1:-}"
    local prompt="${2:-}"

    if [ -z "$interval" ] || [ -z "$prompt" ]; then
        echo "Error: Specify interval in minutes and prompt." >&2
        exit 1
    fi

    local new_id
    new_id=$(jq '(.jobs | map(.id) | max // 0) + 1' "$CRON_FILE")

    local updated
    updated=$(jq --argjson id "$new_id" \
                 --argjson interval "$interval" \
                 --arg prompt "$prompt" \
                 '.jobs += [{"id": $id, "interval_min": $interval, "prompt": $prompt, "last_run": null, "last_timestamp": 0}]' \
                 "$CRON_FILE")
    echo "$updated" > "$CRON_FILE"
    echo "Added job [$new_id]: Every ${interval}m — \"$prompt\""
}

cmd_remove() {
    init_file
    local job_id="${1:-}"
    if [ -z "$job_id" ]; then
        echo "Error: Specify job ID to remove." >&2
        exit 1
    fi

    local updated
    updated=$(jq --argjson id "$job_id" '.jobs |= map(select(.id != $id))' "$CRON_FILE")
    echo "$updated" > "$CRON_FILE"
    echo "Removed job [$job_id]."
}

cmd_daemon() {
    init_file
    echo "Starting claude-cron daemon..."
    while true; do
        sleep 60
        local now_ts
        now_ts=$(date +%s)
        
        # Read jobs count
        local count
        count=$(jq '.jobs | length' "$CRON_FILE" 2>/dev/null || echo 0)

        for ((i=0; i<count; i++)); do
            local job_id interval prompt last_ts
            job_id=$(jq -r ".jobs[$i].id" "$CRON_FILE")
            interval=$(jq -r ".jobs[$i].interval_min" "$CRON_FILE")
            prompt=$(jq -r ".jobs[$i].prompt" "$CRON_FILE")
            last_ts=$(jq -r ".jobs[$i].last_timestamp // 0" "$CRON_FILE")

            local interval_sec=$((interval * 60))
            local elapsed=$((now_ts - last_ts))

            if [ "$elapsed" -ge "$interval_sec" ]; then
                echo "[claude-cron] Running job [$job_id]: $prompt"
                
                # Execute claude task in background
                local output
                output=$(claude -p "$prompt" 2>&1 || true)

                # Send summary to HA notification if ha-notify is available
                if command -v ha-notify >/dev/null 2>&1; then
                    ha-notify "Claude Cron Job [$job_id]" "$output" || true
                fi

                # Update last_run timestamp
                local formatted_date
                formatted_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                local updated
                updated=$(jq --argjson id "$job_id" \
                             --argjson ts "$now_ts" \
                             --arg date "$formatted_date" \
                             '(.jobs[] | select(.id == $id)) |= (.last_timestamp = $ts | .last_run = $date)' \
                             "$CRON_FILE")
                echo "$updated" > "$CRON_FILE"
            fi
        done
    done
}

case "${1:-}" in
    list)
        cmd_list
        ;;
    add)
        cmd_add "${2:-}" "${3:-}"
        ;;
    remove)
        cmd_remove "${2:-}"
        ;;
    daemon)
        cmd_daemon
        ;;
    -h|--help)
        show_help
        ;;
    *)
        show_help
        ;;
esac
