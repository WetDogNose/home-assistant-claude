#!/bin/bash

# claude-hooks — bridge Claude Code's hook events to Home Assistant.
#
# The problem this solves: you start a task from your phone, lock it, and walk
# away. Claude finishes, or stops to ask permission — and nothing tells you.
# The work is invisible until you happen to open the terminal again, which for
# a phone-first workflow is most of the time.
#
# Claude Code fires hooks at exactly the moments that matter (a prompt starts, a
# response ends, Claude needs input), and this add-on already knows how to raise
# a Home Assistant notification, speak on a media player and publish entity
# state. Nothing connected the two. This does.
#
# Runs inside the user's terminal (Claude Code invokes it) — plain bash, no
# bashio, and options are read straight out of /data/options.json.
#
# Usage:
#   claude-hooks install            Write the managed hook block into settings.json
#   claude-hooks remove             Strip the managed hook block
#   claude-hooks status             Show what is installed and how it is configured
#   claude-hooks test               Send a test notification through the same path
#   claude-hooks handle <event>     Invoked by Claude Code, hook JSON on stdin
#
# The handler MUST NOT be able to break a Claude session: it always exits 0, it
# never writes to stdout in a way Claude would read as a directive, and the
# network calls are backgrounded so a slow Supervisor cannot stall a response.

set -o pipefail

SETTINGS_FILE="${CLAUDE_HOOKS_SETTINGS:-${HOME:-/data/home}/.claude/settings.json}"
OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"
RUN_DIR="${CLAUDE_HOOK_RUNDIR:-/run/claude-terminal/hooks}"

# The marker that makes a hook entry ours. Every command this script installs
# starts with it, which is how `install` can withdraw a hook that a previous
# release shipped while leaving hooks the user wrote entirely alone. Same
# discipline as the bundled skills: shipped state, resynced, never accumulated.
MANAGED_PREFIX="claude-hooks handle"

show_help() {
    cat << 'EOF'
claude-hooks — Home Assistant notifications for Claude Code events

Usage:
  claude-hooks install          Install the add-on's hooks into settings.json
  claude-hooks remove           Remove them again (user hooks are untouched)
  claude-hooks status           Show installed hooks and current settings
  claude-hooks test             Send a test notification and speak it if configured
  claude-hooks handle <event>   Internal: called by Claude Code with JSON on stdin

What gets installed:
  UserPromptSubmit  marks the add-on busy in Home Assistant
  Stop              notifies when a response finishes, if it took long enough
  Notification      notifies when Claude is waiting for you (permission, input)
  SessionEnd        clears the busy state

Settings (add-on options):
  notify_on_completion   turn the notifications on or off
  notify_after_seconds   only notify for runs at least this long (default 60)
  notify_tts_target      media_player entity to speak notifications on
  enable_ha_entities     publish binary_sensor.claude_terminal_busy and friends

Environment overrides (for one session or one caller):
  CLAUDE_TERMINAL_NO_HOOK_NOTIFY=1   suppress hooks entirely — set by the
                                     Automation API and claude-cron, which
                                     report their own runs and would otherwise
                                     notify twice for every automated prompt
EOF
}

option() {
    local key="$1" default="$2" value
    [ -f "$OPTIONS_FILE" ] || { printf '%s' "$default"; return 0; }
    # `.[$k] // empty` would be WRONG here: jq's // yields its right-hand side
    # for `false` as well as for null, so every boolean option read this way
    # came back as its default and could not be turned off at all. `has` asks
    # the question actually being asked -- is the key present -- and leaves the
    # value alone.
    value=$(jq -r --arg k "$key" 'if has($k) and .[$k] != null then .[$k] | tostring else empty end' \
        "$OPTIONS_FILE" 2>/dev/null)
    if [ -z "$value" ]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

notifications_enabled() {
    [ "$(option notify_on_completion true)" != "false" ]
}

entities_enabled() {
    [ "$(option enable_ha_entities true)" != "false" ]
}

notify_after_seconds() {
    local value
    value=$(option notify_after_seconds 60)
    case "$value" in
        ''|*[!0-9]*) echo 60 ;;
        *) echo "$value" ;;
    esac
}

# ---------------------------------------------------------------- install ----

# jq filter that removes every hook entry this add-on installed, at any event,
# and drops the groups and events left empty by that removal. Written once and
# reused by both `install` (which re-adds a fresh set afterwards) and `remove`.
#
# It walks .hooks.<Event>[].hooks[] because that is the shape Claude Code
# expects: an event maps to a list of matcher groups, each of which holds a list
# of commands. Anything the user put there that is not ours survives untouched.
strip_managed_filter() {
    cat << 'JQ'
def strip_group:
    .hooks = ((.hooks // []) | map(select(((.command // "") | startswith($prefix)) | not)));

.hooks = (
    (.hooks // {})
    | with_entries(
        .value = (
            (.value // [])
            | map(strip_group)
            | map(select((.hooks | length) > 0))
        )
      )
    | with_entries(select((.value | length) > 0))
)
JQ
}

# One matcher group carrying one command, in the shape Claude Code reads.
hook_entry() {
    jq -nc --arg cmd "$1" \
        '{matcher: "", hooks: [{type: "command", command: $cmd, timeout: 15}]}'
}

cmd_install() {
    local dir tmp filter
    dir=$(dirname "$SETTINGS_FILE")

    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "Error: could not create ${dir}." >&2
        return 1
    fi

    # A settings.json that exists but is not valid JSON is the user's file and
    # the user's problem — refuse rather than replace it, because overwriting
    # would silently discard whatever they were in the middle of writing.
    if [ -s "$SETTINGS_FILE" ] && ! jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
        echo "Error: ${SETTINGS_FILE} is not valid JSON; leaving it alone." >&2
        return 1
    fi
    [ -s "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

    filter=$(strip_managed_filter)

    # Withdraw first, then add back exactly the current set. That is what lets a
    # release drop a hook: a hook installed once into a persistent $HOME would
    # otherwise outlive the version that shipped it.
    if ! notifications_enabled && ! entities_enabled; then
        cmd_remove
        return 0
    fi

    local add_filter=""
    # UserPromptSubmit / SessionEnd only move a local state file, so they are
    # installed whenever entities are on. Stop / Notification are the ones that
    # reach the user, and follow notify_on_completion.
    if entities_enabled; then
        add_filter="${add_filter} | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [\$busy])"
        add_filter="${add_filter} | .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [\$idle])"
    fi
    if notifications_enabled; then
        add_filter="${add_filter} | .hooks.Stop = ((.hooks.Stop // []) + [\$stop])"
        add_filter="${add_filter} | .hooks.Notification = ((.hooks.Notification // []) + [\$waiting])"
    fi

    tmp="${SETTINGS_FILE}.tmp.$$"
    if jq --arg prefix "$MANAGED_PREFIX" \
          --argjson busy    "$(hook_entry "${MANAGED_PREFIX} prompt-submit")" \
          --argjson idle    "$(hook_entry "${MANAGED_PREFIX} session-end")" \
          --argjson stop    "$(hook_entry "${MANAGED_PREFIX} stop")" \
          --argjson waiting "$(hook_entry "${MANAGED_PREFIX} notification")" \
          "${filter}${add_filter}" "$SETTINGS_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$SETTINGS_FILE"
        chmod 600 "$SETTINGS_FILE" 2>/dev/null || true
        return 0
    fi

    rm -f "$tmp"
    echo "Error: could not update ${SETTINGS_FILE}." >&2
    return 1
}

cmd_remove() {
    [ -s "$SETTINGS_FILE" ] || return 0
    jq -e . "$SETTINGS_FILE" >/dev/null 2>&1 || return 0

    local tmp="${SETTINGS_FILE}.tmp.$$"
    if jq --arg prefix "$MANAGED_PREFIX" "$(strip_managed_filter)" \
            "$SETTINGS_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$SETTINGS_FILE"
    else
        rm -f "$tmp"
    fi
    return 0
}

cmd_status() {
    echo "=== Claude Terminal hooks ==="
    echo "Settings file:        $SETTINGS_FILE"
    echo "Notifications:        $(option notify_on_completion true)"
    echo "Notify after:         $(notify_after_seconds)s"
    echo "Speak on:             $(option notify_tts_target '(none)')"
    echo "Publish HA entities:  $(option enable_ha_entities true)"
    if [ -n "${CLAUDE_TERMINAL_NO_HOOK_NOTIFY:-}" ]; then
        echo "Suppressed:           yes (CLAUDE_TERMINAL_NO_HOOK_NOTIFY is set)"
    fi
    echo ""

    if [ ! -s "$SETTINGS_FILE" ]; then
        echo "No settings.json yet — run 'claude-hooks install'."
        return 0
    fi

    echo "Installed hooks:"
    jq -r --arg prefix "$MANAGED_PREFIX" '
        (.hooks // {})
        | to_entries[]
        | .key as $event
        | .value[]?.hooks[]?
        | "  \($event): \(.command)"
          + (if ((.command // "") | startswith($prefix)) then "" else "   [yours]" end)
    ' "$SETTINGS_FILE" 2>/dev/null || echo "  (none)"
}

# ---------------------------------------------------------------- handler ----

# Everything below runs while Claude is waiting for the hook to return, so it
# has to be quick. The network calls go into the background; the caller sees
# only the state-file write.

notify() {
    local title="$1" message="$2" id="$3"
    command -v ha-notify >/dev/null 2>&1 || return 0
    ha-notify "$title" "$message" "$id" >/dev/null 2>&1 || true
}

speak() {
    local message="$1" target
    target=$(option notify_tts_target "")
    [ -n "$target" ] || return 0
    command -v ha-tts >/dev/null 2>&1 || return 0
    ha-tts "$message" "$target" >/dev/null 2>&1 || true
}

set_state() {
    entities_enabled || return 0
    command -v ha-entity >/dev/null 2>&1 || return 0
    ha-entity set "$@" >/dev/null 2>&1 || true
}

# Pull the last thing Claude actually said out of the session transcript, so the
# notification carries the answer rather than just "a task finished". The
# transcript is JSONL, one message per line; `fromjson?` skips a partially
# written final line rather than aborting on it.
last_assistant_text() {
    local transcript="$1" text
    if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
        return 0
    fi

    # -R is not optional: without it jq parses each line into an object, and
    # `fromjson` on an object errors -- swallowed by `?` -- so this returned
    # empty every time and the notification never carried what Claude said.
    text=$(tail -n 400 "$transcript" 2>/dev/null | jq -R -r '
        fromjson? // empty
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text
    ' 2>/dev/null | tail -n 20 | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')

    [ -n "$text" ] || return 0
    if [ "${#text}" -gt 240 ]; then
        printf '%s…' "${text:0:240}"
    else
        printf '%s' "$text"
    fi
}

started_marker() {
    printf '%s/%s.start' "$RUN_DIR" "$(printf '%s' "${1:-unknown}" | tr -c 'a-zA-Z0-9_-' '_')"
}

elapsed_for_session() {
    local marker now started
    marker=$(started_marker "$1")
    [ -f "$marker" ] || { echo -1; return 0; }
    started=$(cat "$marker" 2>/dev/null)
    case "$started" in
        ''|*[!0-9]*) echo -1; return 0 ;;
    esac
    now=$(date +%s)
    echo $(( now - started ))
}

handle_prompt_submit() {
    local session_id="$1"
    mkdir -p "$RUN_DIR" 2>/dev/null || true
    date +%s > "$(started_marker "$session_id")" 2>/dev/null || true
    set_state busy=true status=running last_source=terminal
}

handle_stop() {
    local session_id="$1" transcript="$2" elapsed summary message

    elapsed=$(elapsed_for_session "$session_id")
    rm -f "$(started_marker "$session_id")" 2>/dev/null || true

    set_state busy=false status=idle last_result=ok last_source=terminal \
        "last_run=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"

    notifications_enabled || return 0

    # Every prompt fires Stop. Notifying for all of them would make the drawer
    # useless within a day, and the notification is only wanted for the case it
    # was built for: a run long enough that you stopped watching it.
    local threshold
    threshold=$(notify_after_seconds)
    if [ "$elapsed" -lt 0 ] || [ "$elapsed" -lt "$threshold" ]; then
        return 0
    fi

    summary=$(last_assistant_text "$transcript")
    message="Claude finished after $(format_duration "$elapsed")."
    [ -n "$summary" ] && message="${message}

${summary}"

    notify "Claude Terminal finished" "$message" "claude_terminal_finished"
    speak "Claude has finished your task."
}

handle_notification() {
    local message="$1"
    notifications_enabled || return 0
    [ -n "$message" ] || message="Claude Terminal is waiting for you."

    set_state status=waiting
    notify "Claude Terminal needs you" "$message" "claude_terminal_waiting"
    speak "Claude needs your attention."
}

handle_session_end() {
    local session_id="$1"
    rm -f "$(started_marker "$session_id")" 2>/dev/null || true
    set_state busy=false status=idle
}

format_duration() {
    local seconds="$1"
    if [ "$seconds" -lt 60 ]; then
        printf '%ss' "$seconds"
    elif [ "$seconds" -lt 3600 ]; then
        printf '%sm %ss' "$((seconds / 60))" "$((seconds % 60))"
    else
        printf '%sh %sm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
    fi
}

cmd_handle() {
    local event="$1" foreground="${2:-}" payload session_id transcript message

    # The Automation API and claude-cron both report their own runs. Without
    # this, every automated prompt would also fire these hooks and the user
    # would get two notifications for one job.
    [ -n "${CLAUDE_TERMINAL_NO_HOOK_NOTIFY:-}" ] && return 0

    payload=$(timeout 5 cat 2>/dev/null || true)
    session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)
    transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)
    message=$(printf '%s' "$payload" | jq -r '.message // ""' 2>/dev/null)

    case "$event" in
        prompt-submit)
            handle_prompt_submit "$session_id"
            ;;
        stop)
            # Backgrounded: a Stop hook runs while Claude waits to hand the
            # prompt back, and a Supervisor that takes its full 10s timeout
            # would be 10s of apparently-hung terminal on every long run.
            if [ "$foreground" = "--foreground" ]; then
                handle_stop "$session_id" "$transcript"
            else
                ( handle_stop "$session_id" "$transcript" & ) >/dev/null 2>&1
            fi
            ;;
        notification)
            if [ "$foreground" = "--foreground" ]; then
                handle_notification "$message"
            else
                ( handle_notification "$message" & ) >/dev/null 2>&1
            fi
            ;;
        session-end)
            handle_session_end "$session_id"
            ;;
        *)
            ;;
    esac
    return 0
}

cmd_test() {
    echo "Sending a test notification through the same path the hooks use..."
    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        echo "Warning: SUPERVISOR_TOKEN is not set, so nothing will reach Home Assistant." >&2
    fi
    notify "Claude Terminal" "Test notification from claude-hooks." "claude_terminal_test"
    speak "Claude Terminal test notification."
    set_state status=idle busy=false
    echo "Done. Check your Home Assistant notifications."
}

case "${1:-}" in
    install) cmd_install ;;
    remove)  cmd_remove ;;
    status)  cmd_status ;;
    test)    cmd_test ;;
    handle)
        shift
        # Exit 0 no matter what: a hook that returns non-zero is reported to the
        # user inside their Claude session, and a failed notification must never
        # become an error message in the middle of someone's work.
        cmd_handle "${1:-}" "${2:-}" || true
        exit 0
        ;;
    -h|--help|help) show_help ;;
    *) show_help; exit 1 ;;
esac
