#!/bin/bash

# claude-login-url — extract the most recent OAuth login URL from the Claude
# tmux session and save it to /config, where it can be opened via the Home
# Assistant File Editor or Samba and copied without going through the
# terminal clipboard at all.
#
# Why: the browser terminal's OSC 52 clipboard path truncates long payloads
# (~400 chars), and Claude Code's login URL is ~450+ chars — the tail (the
# `state` parameter) gets cut off, which makes authorization fail with
# "Invalid request format".
#
# Reassembling the URL out of the pane is login-url-lib.sh's job: Claude Code
# hard-wraps it, so it arrives as several separate lines that capture-pane
# cannot rejoin on its own.

LIB=""
for candidate in "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/login-url-lib.sh" \
                 /opt/scripts/login-url-lib.sh; do
    if [ -f "$candidate" ]; then LIB="$candidate"; break; fi
done

if [ -z "$LIB" ]; then
    echo "claude-login-url: login-url-lib.sh not found." >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

OUT="${1:-/config/claude-login-url.txt}"

if ! url=$(capture_login_url); then
    echo "No complete login URL found in the Claude session." >&2
    echo "Start the login in Claude first (run /login), leave the URL on screen," >&2
    echo "then run this command again." >&2
    exit 1
fi

printf '%s\n' "$url" > "$OUT"
chmod 600 "$OUT"

# Also push it to Home Assistant's notification drawer, where it can be
# selected and copied with the browser's own clipboard rather than fighting
# the terminal's OSC 52 truncation -- which is the whole reason this script
# has to exist.
if [ -x /usr/local/bin/ha-notify ]; then
    /usr/local/bin/ha-notify \
        "Claude Terminal sign-in" \
        "Open this URL to authorise Claude Code, then return to the terminal and paste the code:

[👉 Authorize Claude Code](${url})

Or copy the URL:
${url}

Dismiss this notification once you are signed in." \
        "claude_terminal_login" && echo "Also sent to Home Assistant notifications."
fi

echo "Login URL saved to: $OUT"
echo "Open it with the Home Assistant File Editor (or over Samba), copy the"
echo "whole line into your browser, and authorize. Delete the file afterwards."
