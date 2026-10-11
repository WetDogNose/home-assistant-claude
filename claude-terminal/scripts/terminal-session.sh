#!/bin/bash

# terminal-session — create the add-on's tmux session if needed, then attach.
#
# ttyd runs this for every browser connection. It replaces a bare
# `tmux new-session -A -s claude '<cmd>'`, which can only ever describe one
# window: the session now has two, Claude and OpenCode, and both have to exist
# before the first client attaches.
#
# Usage:
#   terminal-session <command for window 1>
#
# Environment:
#   CLAUDE_TERMINAL_OPENCODE   "1" adds the OpenCode window
#   TERMINAL_SESSION_NAME      session name (default: claude)
#   TERMINAL_SESSION_NO_ATTACH "1" creates without attaching (tests)
#
# Runs under ttyd — plain bash, no bashio. run.sh reads the options and passes
# the result in, because bashio is not available here.

SESSION="${TERMINAL_SESSION_NAME:-claude}"
MAIN_COMMAND="${1:-/usr/local/bin/welcome --shell}"

# `=` forces an exact match. Without it tmux matches by prefix, and a session
# named "claude-something" created by hand would be mistaken for this one.
if ! tmux has-session -t "=${SESSION}" 2>/dev/null; then
    # Two browser tabs opening at once race here. The loser's new-session fails
    # with "duplicate session", which is fine -- it attaches below -- but it
    # must not go on to add a second OpenCode window to the winner's session.
    if tmux new-session -d -s "$SESSION" -n claude "$MAIN_COMMAND" 2>/dev/null; then
        if [ "${CLAUDE_TERMINAL_OPENCODE:-}" = "1" ]; then
            # -d: created in the background, so the session opens on Claude
            # exactly as it did before this window existed.
            tmux new-window -d -t "=${SESSION}:" -n opencode \
                'opencode-launch --wait' 2>/dev/null || true
        fi
    fi
fi

[ "${TERMINAL_SESSION_NO_ATTACH:-}" = "1" ] && exit 0

exec tmux attach-session -t "=${SESSION}"
