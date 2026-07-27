#!/bin/bash

# HA Smart Context — generates a CLAUDE.md with Home Assistant context
#
# Written to $HOME/.claude/CLAUDE.md, which is Claude Code's USER memory file.
# This previously wrote $HOME/CLAUDE.md, which Claude never loads: user memory
# is ~/.claude/CLAUDE.md and project memory is ./CLAUDE.md discovered upward
# from the working directory (/config). $HOME/CLAUDE.md is neither, so the
# whole ha_smart_context feature silently did nothing.
#
# Usage:
#   ha-context          Generate medium-detail context (default)
#   ha-context --full   Include entity ID listings per domain
#   ha-context --help   Show usage

SUPERVISOR_URL="http://supervisor"
OUTPUT_FILE="${HOME}/.claude/CLAUDE.md"
FULL_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            FULL_MODE=true
            shift
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: ha-context [OPTIONS]"
            echo ""
            echo "Generate Home Assistant context for Claude Code sessions."
            echo "Writes a CLAUDE.md file that Claude automatically loads."
            echo ""
            echo "Options:"
            echo "  --full       Include entity ID listings (detailed mode)"
            echo "  --output F   Write to file F instead of \$HOME/.claude/CLAUDE.md"
            echo "  --help       Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run 'ha-context --help' for usage" >&2
            exit 1
            ;;
    esac
done

# --- API helpers ---

api_call() {
    local endpoint="$1"
    curl -s -m 10 \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        "${SUPERVISOR_URL}/${endpoint}" 2>/dev/null
}

ha_api_call() {
    local endpoint="$1"
    api_call "core/api/${endpoint}"
}

check_prerequisites() {
    if [ -z "$SUPERVISOR_TOKEN" ]; then
        echo "Error: SUPERVISOR_TOKEN not set. This script must run inside a Home Assistant add-on." >&2
        exit 1
    fi

    for cmd in curl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: '$cmd' is required but not installed." >&2
            exit 1
        fi
    done
}

# --- Section generators ---
# Each function outputs markdown to stdout. Failures produce fallback text.

section_system_info() {
    local core_info ha_config host_info

    core_info=$(api_call "core/info")
    host_info=$(api_call "host/info")
    ha_config=$(ha_api_call "config")

    local ha_version machine ha_os
    ha_version=$(echo "$core_info" | jq -r '.data.version // empty' 2>/dev/null)
    machine=$(echo "$core_info" | jq -r '.data.machine // empty' 2>/dev/null)
    ha_os=$(echo "$host_info" | jq -r '.data.operating_system // empty' 2>/dev/null)

    local hostname timezone location_name
    hostname=$(echo "$host_info" | jq -r '.data.hostname // empty' 2>/dev/null)
    timezone=$(echo "$ha_config" | jq -r '.time_zone // empty' 2>/dev/null)
    location_name=$(echo "$ha_config" | jq -r '.location_name // empty' 2>/dev/null)

    if [ -z "$ha_version" ]; then
        echo "Unable to retrieve system information."
        return
    fi

    echo "- **Home Assistant**: ${ha_version}"
    [ -n "$machine" ] && echo "- **Machine**: ${machine}"
    [ -n "$ha_os" ] && echo "- **OS**: ${ha_os}"
    [ -n "$hostname" ] && echo "- **Hostname**: ${hostname}"
    [ -n "$location_name" ] && echo "- **Location**: ${location_name}"
    [ -n "$timezone" ] && echo "- **Timezone**: ${timezone}"
}

# Fetched once and reused. section_entity_summary and section_addons both
# needed this payload and were each pulling it separately, which on a large
# instance is two multi-megabyte responses for one document.
STATES_CACHE=""
get_states() {
    if [ -z "$STATES_CACHE" ]; then
        STATES_CACHE=$(ha_api_call "states")
    fi
    printf '%s' "$STATES_CACHE"
}

section_entity_summary() {
    local states
    states=$(get_states)

    if [ -z "$states" ] || ! echo "$states" | jq -e '.' >/dev/null 2>&1; then
        echo "Unable to retrieve entity states."
        return
    fi

    local total
    total=$(echo "$states" | jq 'length')

    # Count by domain
    local summary
    summary=$(echo "$states" | jq -r '
        [.[].entity_id | split(".")[0]] | group_by(.) |
        map({domain: .[0], count: length}) |
        sort_by(-.count) |
        .[] | "| \(.domain) | \(.count) |"
    ' 2>/dev/null)

    if [ -z "$summary" ]; then
        echo "0 entities found."
        return
    fi

    echo "| Domain | Count |"
    echo "|--------|-------|"
    echo "$summary"
    echo ""
    echo "**Total: ${total} entities**"

    # Full mode: list entity IDs per domain
    if [ "$FULL_MODE" = true ]; then
        echo ""
        echo "### Entity Details"
        echo ""

        local domains
        domains=$(echo "$states" | jq -r '
            [.[].entity_id | split(".")[0]] | unique | sort | .[]
        ' 2>/dev/null)

        for domain in $domains; do
            local entities count
            entities=$(echo "$states" | jq -r --arg d "$domain" '
                [.[] | select(.entity_id | startswith($d + ".")) | .entity_id] | sort | .[]
            ' 2>/dev/null)
            count=$(echo "$entities" | wc -l)

            echo "**${domain}** (${count}):"

            # Cap at 10 per domain
            local shown=0
            while IFS= read -r entity_id; do
                [ -z "$entity_id" ] && continue
                echo "- \`${entity_id}\`"
                shown=$((shown + 1))
                if [ "$shown" -ge 10 ] && [ "$count" -gt 10 ]; then
                    local remaining=$((count - 10))
                    echo "- *...and ${remaining} more*"
                    break
                fi
            done <<< "$entities"
            echo ""
        done
    fi
}

# Add-ons are read from the update entities Home Assistant already publishes
# for each one, rather than from the Supervisor's /addons route.
#
# That route is the ONLY call in this add-on that required hassio_role: manager,
# and manager also grants /backups (which can export every secret in the
# instance), /store, /host reboot and /mounts -- none of which anything here
# uses. Sourcing the same information from the states payload we have already
# fetched lets the role drop to default, and costs one fewer API call.
section_addons() {
    local states
    states=$(get_states)

    if [ -z "$states" ] || ! echo "$states" | jq -e '.' >/dev/null 2>&1; then
        echo "Unable to retrieve add-on information."
        return
    fi

    local addons
    addons=$(echo "$states" | jq -r '
        [ .[]
          | select(.entity_id | startswith("update."))
          | select(.attributes.installed_version != null)
          | select(.entity_id | test("home_assistant_(core|supervisor|operating_system)") | not)
          | "- \(.attributes.title // .attributes.friendly_name // .entity_id) v\(.attributes.installed_version)"
            + (if .state == "on" then " (update available: \(.attributes.latest_version))" else "" end)
        ] | sort | .[]
    ' 2>/dev/null)

    if [ -z "$addons" ]; then
        echo "No add-on update entities found."
        return
    fi
    echo "$addons"
}

# Deliberately no error-log section.
#
# It captured 20 lines of the error log at generation time and froze them into
# a file Claude reads on every session. That is stale within minutes, invites
# Claude to reason about errors that were fixed hours ago, and copies whatever
# happened to be in the log -- tokens, IPs, entity names -- into a file that
# persists in /data. Claude can read the live log on demand instead, which is
# both accurate and scoped to when it is actually needed.
section_error_hint() {
    echo "Read the current error log when you need it:"
    echo ""
    echo '```bash'
    echo 'curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \'
    echo '  http://supervisor/core/api/error_log | tail -50'
    echo '```'
}

# --- Main generation ---

generate_claude_md() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$(dirname "$OUTPUT_FILE")"

    local tmp_file
    tmp_file=$(mktemp "${OUTPUT_FILE}.XXXXXX")

    cat > "$tmp_file" << HEADER
# Home Assistant Context

> Auto-generated by Claude Terminal add-on. Run \`ha-context\` to refresh.
> Last updated: ${timestamp}

## System

HEADER

    section_system_info >> "$tmp_file"

    cat >> "$tmp_file" << 'DIVIDER'

## Entities

DIVIDER

    section_entity_summary >> "$tmp_file"

    cat >> "$tmp_file" << 'DIVIDER'

## Installed Add-ons

DIVIDER

    section_addons >> "$tmp_file"

    cat >> "$tmp_file" << 'DIVIDER'

## Errors

DIVIDER

    section_error_hint >> "$tmp_file"

    cat >> "$tmp_file" << 'APIREF'

## API Access

You have full access to the Home Assistant APIs from this terminal:

```bash
# Supervisor API
curl -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/info

# Entity states
curl -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states

# Call a service
curl -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "light.living_room"}' \
  http://supervisor/core/api/services/light/turn_on
```

Available endpoints: `states`, `services`, `config`, `events`, `error_log`, `history/period`
APIREF

    # Atomic move
    chmod 644 "$tmp_file"
    mv "$tmp_file" "$OUTPUT_FILE"
}

main() {
    check_prerequisites

    echo "Generating Home Assistant context..." >&2

    generate_claude_md

    local detail="medium"
    [ "$FULL_MODE" = true ] && detail="full"

    echo "HA context (${detail}) written to ${OUTPUT_FILE}" >&2
}

main "$@"
