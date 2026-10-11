#!/bin/bash

# ha-entity — publish the add-on's own state into Home Assistant as entities.
#
# Every other HA-facing script in this add-on READS Home Assistant. Nothing
# wrote back, which meant the add-on itself was invisible to the system it runs
# inside: whether Claude is busy, whether it needs a sign-in, when it last ran
# and how that run ended were all facts that existed only in a log or a
# terminal nobody had open. Automations could call Claude but could not react
# to it, and a dashboard could not show it at all.
#
# Runs inside the user's terminal as well as from daemons — plain bash, no
# bashio (ttyd's environment does not provide it).
#
# Usage:
#   ha-entity sync                     Publish every entity from the state file
#   ha-entity set <key>=<value> ...    Update state keys, then publish
#   ha-entity show                     Print the current state file
#   ha-entity publish <id> <state> [attributes-json]
#   ha-entity heartbeat [seconds]      Re-publish on a loop (daemon)
#
# A leading `--agent opencode` switches every command to OpenCode's state file
# and its own entities (binary_sensor.opencode_busy, sensor.opencode_*). With
# no flag the behaviour is exactly what it was before OpenCode existed, so
# every existing caller is unaffected.
#
# States created through the REST API are RUNTIME state: Home Assistant does not
# persist them, so every one of these entities disappears when Core restarts and
# stays gone until something publishes it again. That is what `heartbeat` is
# for, and why run.sh starts one — without it the entities would work perfectly
# until the first Home Assistant restart and then quietly vanish, which is a
# worse failure than never having shipped them.

set -o pipefail

STATE_FILE="${CLAUDE_STATE_FILE:-/data/claude-state.json}"
HEARTBEAT_SECONDS="${CLAUDE_ENTITY_HEARTBEAT_SECONDS:-300}"
DEFAULT_STATE='{"status":"idle","busy":false,"login_required":false,"last_run":"","last_result":"","last_error":"","last_source":"","version":""}'

# OpenCode keeps its own state file rather than extra keys in Claude's: the two
# are written by unrelated processes, and a shared document would have each
# one's writes contending for the other's lock.
OPENCODE_STATE_FILE="${OPENCODE_STATE_FILE:-/data/opencode-state.json}"

AGENT="claude"
if [ "${1:-}" = "--agent" ]; then
    AGENT="${2:-}"
    shift 2 2>/dev/null || shift $#
fi
case "$AGENT" in
    claude) ;;
    opencode)
        STATE_FILE="$OPENCODE_STATE_FILE"
        # No login_required and no last_source: OpenCode has no single sign-in
        # to wait on, and only one way of being started.
        DEFAULT_STATE='{"status":"idle","busy":false,"last_run":"","last_result":"","last_error":"","model":"","version":""}'
        ;;
    *)
        echo "ha-entity: unknown agent '${AGENT}' (expected: opencode)." >&2
        exit 1
        ;;
esac

# setup_commands COPIES this script to /usr/local/bin/ha-entity, so the library
# is not beside the running copy -- $(dirname "$0") finds it only when running
# straight out of the repo or /opt/scripts. Same two-candidate lookup as
# claude-login-url.sh, for the same reason.
LIB=""
for candidate in "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/state-lib.sh" \
                 /opt/scripts/state-lib.sh; do
    if [ -f "$candidate" ]; then LIB="$candidate"; break; fi
done

if [ -z "$LIB" ]; then
    echo "ha-entity: state-lib.sh not found." >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

show_help() {
    cat << 'EOF'
ha-entity — publish Claude Terminal's own state to Home Assistant

Usage:
  ha-entity sync                        Publish every entity from the state file
  ha-entity set <key>=<value> [...]     Update state keys and publish
  ha-entity show                        Print the current state
  ha-entity publish <entity_id> <state> [attributes-json]
  ha-entity heartbeat [seconds]         Re-publish on a loop

  ha-entity --agent opencode <command>  The same, for OpenCode's entities

Known keys:
  status          idle | running | error | login_required
  busy            true | false
  login_required  true | false
  last_run        ISO-8601 timestamp of the last completed run
  last_result     ok | error | timeout
  last_error      free text, shown as an attribute
  last_source     terminal | api | cron
  version         add-on version

Entities published:
  binary_sensor.claude_terminal_busy
  binary_sensor.claude_terminal_login_required
  sensor.claude_terminal_status
  sensor.claude_terminal_last_run
  sensor.claude_terminal_last_result
  sensor.claude_terminal_version

With --agent opencode (keys: status, busy, last_run, last_result, last_error,
model, version; status is idle | running | retrying | waiting | error):
  binary_sensor.opencode_busy
  sensor.opencode_status
  sensor.opencode_last_run
  sensor.opencode_last_result
  sensor.opencode_version

Home Assistant does not persist API-created states, so they vanish on a Core
restart until something republishes them. `ha-entity heartbeat` (started by the
add-on) is what brings them back.

Examples:
  ha-entity set busy=true status=running last_source=cron
  ha-entity sync
EOF
}

require_token() {
    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        echo "Error: SUPERVISOR_TOKEN is not set; this must run inside the add-on." >&2
        return 1
    fi
}

# domain.object_id and nothing else. The id is a path component of the URL
# publish_entity posts to, and curl collapses "../": `ha-entity publish
# ../services/<domain>/<service> x` was a call to another Core API route under
# the add-on's token.
valid_entity_id() {
    case "$1" in
        *[!a-z0-9_.]*|.*|*.|*.*.*) return 1 ;;
        *.*) return 0 ;;
    esac
    return 1
}

# POST one entity state. Never fails into a caller's `set -e`: this is
# reporting, and reporting must not be able to break the thing it reports on.
publish_entity() {
    # Not "${3:-{\}}": inside double quotes the backslash is kept, so the
    # default was the three characters {\} -- invalid JSON, and a publish
    # with no attributes silently sent nothing.
    local entity_id="$1" state="$2" attributes="${3:-}" payload
    [ -n "$attributes" ] || attributes='{}'

    [ -n "$entity_id" ] || return 0
    [ -n "${SUPERVISOR_TOKEN:-}" ] || return 0
    valid_entity_id "$entity_id" || return 0

    payload=$(jq -nc --arg s "$state" --argjson a "$attributes" \
        '{state: $s, attributes: $a}' 2>/dev/null) || return 0

    curl -fsS -m 10 -o /dev/null \
        -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://supervisor/core/api/states/${entity_id}" \
        2>/dev/null || return 0
}

state_get() {
    json_read "$STATE_FILE" "$DEFAULT_STATE" "$1"
}

# Booleans arrive from shell as the strings "true"/"false" and from jq as real
# booleans; normalise both to the on/off a binary_sensor requires. Anything
# unrecognised is "off", because a binary_sensor with an invalid state is shown
# as unavailable and would read as "the add-on is broken".
on_off() {
    case "$1" in
        true|True|TRUE|on|1|yes) echo "on" ;;
        *) echo "off" ;;
    esac
}

# Publish all six entities CONCURRENTLY.
#
# Sequentially these are six `curl -m 10` calls, so a Supervisor that is slow --
# which is exactly what it is while Home Assistant Core is still starting, i.e.
# when add-ons boot -- costs up to 60 seconds. That is a minute of blocked
# caller: the boot path, or a Claude Code hook that Claude is waiting on.
# Fired together, the worst case is one timeout rather than six.
publish_all() {
    local pid pids=()
    while [ "$#" -gt 0 ]; do
        publish_entity "$1" "$2" "$3" &
        pids+=("$!")
        shift 3
    done
    for pid in ${pids[@]+"${pids[@]}"}; do
        wait "$pid" 2>/dev/null || true
    done
}

cmd_sync_opencode() {
    local status busy last_run last_result last_error model version
    status=$(state_get '.status // "idle"')
    busy=$(state_get '.busy // false')
    last_run=$(state_get '.last_run // ""')
    last_result=$(state_get '.last_result // ""')
    last_error=$(state_get '.last_error // ""')
    model=$(state_get '.model // ""')
    version=$(state_get '.version // ""')
    [ -n "$version" ] || version="unknown"

    # Same rule as Claude's last_run: never publish "" under a timestamp
    # device_class.
    local last_run_state="unknown" last_run_attrs
    if [ -n "$last_run" ]; then
        last_run_state="$last_run"
        last_run_attrs=$(jq -nc --arg n "OpenCode Last Run" \
            '{friendly_name: $n, icon: "mdi:clock-outline", device_class: "timestamp"}')
    else
        last_run_attrs=$(jq -nc --arg n "OpenCode Last Run" \
            '{friendly_name: $n, icon: "mdi:clock-outline"}')
    fi

    publish_all \
        "binary_sensor.opencode_busy" "$(on_off "$busy")" \
        "$(jq -nc --arg n "OpenCode Busy" \
            '{friendly_name: $n, icon: "mdi:robot-outline", device_class: "running"}')" \
        "sensor.opencode_status" "$status" \
        "$(jq -nc --arg n "OpenCode Status" --arg m "$model" \
            --arg v "$(cat /opt/scripts/addon-version 2>/dev/null || echo unknown)" \
            '{friendly_name: $n, icon: "mdi:console-line", model: $m, addon_version: $v}')" \
        "sensor.opencode_last_run" "$last_run_state" "$last_run_attrs" \
        "sensor.opencode_last_result" "${last_result:-unknown}" \
        "$(jq -nc --arg n "OpenCode Last Result" --arg e "$last_error" \
            '{friendly_name: $n, icon: "mdi:check-circle-outline", error: $e}')" \
        "sensor.opencode_version" "$version" \
        "$(jq -nc --arg n "OpenCode Version" \
            '{friendly_name: $n, icon: "mdi:tag-outline"}')"
}

cmd_sync() {
    require_token || return 1
    if [ "$AGENT" = "opencode" ]; then
        cmd_sync_opencode
        return
    fi

    local status busy login_required last_run last_result last_error last_source version
    status=$(state_get '.status // "idle"')
    busy=$(state_get '.busy // false')
    login_required=$(state_get '.login_required // false')
    last_run=$(state_get '.last_run // ""')
    last_result=$(state_get '.last_result // ""')
    last_error=$(state_get '.last_error // ""')
    last_source=$(state_get '.last_source // ""')
    version=$(state_get '.version // ""')
    [ -n "$version" ] || version=$(cat /opt/scripts/addon-version 2>/dev/null || echo "unknown")

    local last_run_state="unknown" last_run_attrs
    # An empty timestamp must NOT be published as "": Home Assistant rejects a
    # timestamp device_class it cannot parse and logs an error every heartbeat.
    # "unknown" is the documented placeholder and renders as such in the UI.
    if [ -n "$last_run" ]; then
        last_run_state="$last_run"
        last_run_attrs=$(jq -nc --arg n "Claude Terminal Last Run" \
            '{friendly_name: $n, icon: "mdi:clock-outline", device_class: "timestamp"}')
    else
        last_run_attrs=$(jq -nc --arg n "Claude Terminal Last Run" \
            '{friendly_name: $n, icon: "mdi:clock-outline"}')
    fi

    publish_all \
        "binary_sensor.claude_terminal_busy" "$(on_off "$busy")" \
        "$(jq -nc --arg n "Claude Terminal Busy" --arg s "$last_source" \
            '{friendly_name: $n, icon: "mdi:robot", device_class: "running", source: $s}')" \
        "binary_sensor.claude_terminal_login_required" "$(on_off "$login_required")" \
        "$(jq -nc --arg n "Claude Terminal Login Required" \
            '{friendly_name: $n, icon: "mdi:account-key", device_class: "problem"}')" \
        "sensor.claude_terminal_status" "$status" \
        "$(jq -nc --arg n "Claude Terminal Status" --arg v "$version" \
            '{friendly_name: $n, icon: "mdi:console", addon_version: $v}')" \
        "sensor.claude_terminal_last_run" "$last_run_state" "$last_run_attrs" \
        "sensor.claude_terminal_last_result" "${last_result:-unknown}" \
        "$(jq -nc --arg n "Claude Terminal Last Result" --arg e "$last_error" --arg s "$last_source" \
            '{friendly_name: $n, icon: "mdi:check-circle-outline", error: $e, source: $s}')" \
        "sensor.claude_terminal_version" "$version" \
        "$(jq -nc --arg n "Claude Terminal Version" \
            '{friendly_name: $n, icon: "mdi:tag-outline"}')"
}

cmd_set() {
    [ "$#" -gt 0 ] || { echo "Error: nothing to set." >&2; return 1; }

    local pair key value filter="." args=() i=0
    for pair in "$@"; do
        case "$pair" in
            *=*) ;;
            *) echo "Error: expected key=value, got '${pair}'." >&2; return 1 ;;
        esac
        key="${pair%%=*}"
        value="${pair#*=}"

        case "$key" in
            [a-z_]*) ;;
            *) echo "Error: invalid key '${key}'." >&2; return 1 ;;
        esac

        # true/false are stored as JSON booleans so `.busy` reads the same way
        # from jq whether it was set here or by the API server.
        case "$value" in
            true|false)
                filter="${filter} | .[\$k${i}] = (\$v${i} == \"true\")"
                ;;
            *)
                filter="${filter} | .[\$k${i}] = \$v${i}"
                ;;
        esac
        args+=(--arg "k${i}" "$key" --arg "v${i}" "$value")
        i=$((i + 1))
    done

    json_update "$STATE_FILE" "$DEFAULT_STATE" "${args[@]}" "$filter" || {
        echo "Error: could not update ${STATE_FILE}." >&2
        return 1
    }

    # Publishing is best-effort: outside a Supervisor (local development, or a
    # hook firing while Core is restarting) the state file is still the record
    # that matters, and the next heartbeat will carry it.
    [ -n "${SUPERVISOR_TOKEN:-}" ] && cmd_sync
    return 0
}

cmd_show() {
    if [ -s "$STATE_FILE" ]; then
        jq . "$STATE_FILE"
    else
        printf '%s\n' "$DEFAULT_STATE" | jq .
    fi
}

cmd_heartbeat() {
    local interval="${1:-$HEARTBEAT_SECONDS}"
    case "$interval" in
        ''|*[!0-9]*) interval="$HEARTBEAT_SECONDS" ;;
    esac
    [ "$interval" -ge 30 ] || interval=30

    while true; do
        cmd_sync || true
        # OpenCode's entities ride the same heartbeat. The state file is the
        # switch: run.sh seeds it only when OpenCode and entities are both on.
        if [ "$AGENT" = "claude" ] && [ -f "$OPENCODE_STATE_FILE" ]; then
            "$0" --agent opencode sync >/dev/null 2>&1 || true
        fi
        sleep "$interval"
    done
}

case "${1:-}" in
    sync)
        cmd_sync
        ;;
    set)
        shift
        cmd_set "$@"
        ;;
    show)
        cmd_show
        ;;
    publish)
        require_token || exit 1
        if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            echo "Usage: ha-entity publish <entity_id> <state> [attributes-json]" >&2
            exit 1
        fi
        if ! valid_entity_id "$2"; then
            echo "ha-entity: not an entity id (expected domain.object_id): $(printf '%s' "$2" | tr -c 'A-Za-z0-9_.' '?' | cut -c1-80)" >&2
            exit 1
        fi
        publish_entity "$2" "$3" "${4:-}"
        ;;
    heartbeat)
        require_token || exit 1
        cmd_heartbeat "${2:-}"
        ;;
    -h|--help|help)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
