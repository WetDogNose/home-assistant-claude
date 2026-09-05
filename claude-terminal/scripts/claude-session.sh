#!/bin/bash

# claude-session — run more than one Claude at a time.
#
# ttyd launches `tmux new-session -A -s claude`, which is deliberate: -A is what
# makes a browser reconnect land back in the session you left rather than
# stacking a new one. The side effect is that everyone is pinned to a single
# session, so a long refactor and a quick "what is the porch light doing" cannot
# happen at once — the second question waits for the first task to finish.
#
# tmux can already do this; what was missing was a way to reach it that does not
# require knowing the prefix chords. This wraps the three commands that matter
# and leaves the primary session alone.
#
# Runs inside the user's terminal — plain bash, no bashio.
#
# Usage:
#   claude-session list
#   claude-session new [name]
#   claude-session switch <name>
#   claude-session kill <name>

set -o pipefail

# The session ttyd attaches to. Killing it disconnects the browser, so it is
# guarded rather than treated like any other name.
PRIMARY="claude"

show_help() {
    cat << 'EOF'
claude-session — run several Claude sessions side by side

Usage:
  claude-session list                 Show every session and what it is running
  claude-session new [name]           Start a new Claude session and switch to it
  claude-session switch <name>        Move this terminal to another session
  claude-session kill <name>          End a session (and whatever it was doing)

Notes:
  Sessions survive closing the browser tab — that is the point. Reopening the
  add-on returns you to "claude", the session ttyd attaches to; use
  `claude-session switch` to get back to the others.

  The "claude" session is the one the browser is attached to, so killing it
  would disconnect you. It is refused unless you pass --force.

  Inside tmux you can also do this with the prefix: Ctrl+B s picks a session
  from a list, Ctrl+B d detaches.

Examples:
  claude-session new refactor
  claude-session list
  claude-session switch claude
EOF
}

require_tmux() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo "Error: tmux is not available." >&2
        return 1
    fi
    if ! tmux list-sessions >/dev/null 2>&1; then
        echo "Error: no tmux server is running. Open the Claude Terminal first." >&2
        return 1
    fi
}

# tmux session names cannot contain a colon or a full stop (both are target
# separators in tmux's own addressing), and a name with spaces makes every
# subsequent command need quoting the user will not expect.
valid_name() {
    case "$1" in
        ''|*[!a-zA-Z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# tmux target names, made EXACT.
#
# A bare `-t claude` is a prefix/fnmatch pattern to tmux, not a name: `kill clau`
# or `kill 'claude*'` would resolve to the primary session while the
# `[ "$name" = "$PRIMARY" ]` guard below saw something else entirely and let it
# through -- disconnecting the browser the guard exists to protect. The `=`
# prefix is tmux's own "exact name" syntax.
exact() {
    printf '=%s' "$1"
}

current_session() {
    tmux display-message -p '#S' 2>/dev/null
}

cmd_list() {
    require_tmux || return 1
    local current
    current=$(current_session)

    echo "=== Claude Terminal sessions ==="
    tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{t:session_created}' 2>/dev/null \
        | while IFS='|' read -r name windows attached created; do
            local marker="  "
            [ "$name" = "$current" ] && marker="* "
            printf '%s%-20s %s window(s), %s, started %s\n' \
                "$marker" "$name" "$windows" \
                "$([ "$attached" != "0" ] && echo "attached" || echo "detached")" \
                "$created"
        done
    echo ""
    echo "* = the session you are in.  claude-session switch <name> to move."
}

# The command a new session runs. claude-launch, not claude, for exactly the
# reason ttyd uses it: it probes the binary and degrades to a shell with an
# explanation rather than dying instantly and leaving an empty session.
session_command() {
    if command -v claude-launch >/dev/null 2>&1; then
        echo "claude-launch"
    else
        echo "claude"
    fi
}

cmd_new() {
    require_tmux || return 1
    local name="${1:-}"

    if [ -z "$name" ]; then
        # Lowest free claude-N, so repeated calls do not collide and the names
        # stay predictable.
        local n=2
        while tmux has-session -t "$(exact "claude-${n}")" 2>/dev/null; do
            n=$((n + 1))
        done
        name="claude-${n}"
    fi

    if ! valid_name "$name"; then
        echo "Error: '${name}' is not a usable session name (letters, digits, - and _ only)." >&2
        return 1
    fi

    if tmux has-session -t "$(exact "$name")" 2>/dev/null; then
        echo "Session '${name}' already exists; switching to it."
        cmd_switch "$name"
        return $?
    fi

    if ! tmux new-session -d -s "$name" "$(session_command)"; then
        echo "Error: could not create session '${name}'." >&2
        return 1
    fi
    echo "Started session '${name}'."
    cmd_switch "$name"
}

cmd_switch() {
    require_tmux || return 1
    local name="${1:-}"

    if [ -z "$name" ]; then
        echo "Error: which session? Try 'claude-session list'." >&2
        return 1
    fi
    if ! valid_name "$name"; then
        echo "Error: '${name}' is not a usable session name (letters, digits, - and _ only)." >&2
        return 1
    fi
    if ! tmux has-session -t "$(exact "$name")" 2>/dev/null; then
        echo "Error: no session named '${name}'." >&2
        return 1
    fi

    # switch-client works from inside tmux; attach-session is for a caller that
    # is not in one (the shell-mode terminal, or a script).
    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$(exact "$name")"
    else
        tmux attach-session -t "$(exact "$name")"
    fi
}

cmd_kill() {
    require_tmux || return 1
    local name="${1:-}" force="${2:-}"

    if [ -z "$name" ]; then
        echo "Error: which session? Try 'claude-session list'." >&2
        return 1
    fi
    if ! valid_name "$name"; then
        echo "Error: '${name}' is not a usable session name (letters, digits, - and _ only)." >&2
        return 1
    fi
    if ! tmux has-session -t "$(exact "$name")" 2>/dev/null; then
        echo "Error: no session named '${name}'." >&2
        return 1
    fi

    if [ "$name" = "$PRIMARY" ] && [ "$force" != "--force" ]; then
        echo "Refusing to kill '${PRIMARY}': it is the session the browser is attached to," >&2
        echo "so this would disconnect the terminal. Pass --force if that is what you want." >&2
        return 1
    fi

    tmux kill-session -t "$(exact "$name")" && echo "Killed session '${name}'."
}

case "${1:-}" in
    list|ls)         cmd_list ;;
    new|create)      cmd_new "${2:-}" ;;
    switch|attach)   cmd_switch "${2:-}" ;;
    kill|rm)         cmd_kill "${2:-}" "${3:-}" ;;
    -h|--help|help)  show_help ;;
    *)               show_help; exit 1 ;;
esac
