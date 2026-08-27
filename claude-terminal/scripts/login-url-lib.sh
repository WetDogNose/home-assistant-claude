# shellcheck shell=bash
# login-url-lib.sh — reassemble Claude Code's OAuth sign-in URL out of the
# terminal it was printed to. Sourced by claude-login-url.sh and
# claude-login-notifier.sh; not a command in its own right.
#
# Why this is not a one-line grep:
#
# Claude Code renders the sign-in URL through Ink, which measures the URL
# against the terminal width and *hard-wraps* it — the pane really does contain
# three or four separate lines, each ending in a newline Claude Code wrote
# itself. `tmux capture-pane -J` only rejoins lines the terminal soft-wrapped,
# so it cannot put those back together, and `grep -o https://...` walks away
# with the first chunk alone: a URL missing `code_challenge`, `state` and
# everything else past the first terminal width. That URL is well-formed and
# clickable and fails at claude.com with an authorization error — which is
# what the sign-in notification was shipping.
#
# So: find the line the URL starts on, then keep appending the lines below it
# for as long as they still look like the continuation of a wrapped URL. Every
# wrapped fragment fills the wrap width exactly, so the first fragment that
# comes up short is the end of the URL.

# Longest URL we will reassemble. The real one is ~450 characters; this only
# stops a pane full of URL-shaped text from growing the buffer forever.
LOGIN_URL_MAX_LEN=4096

# login_url_from_text — read terminal text on stdin, print the last complete
# URL found (no output if there is none).
login_url_from_text() {
    awk -v maxlen="${LOGIN_URL_MAX_LEN}" '
        function trim(s) { sub(/\r$/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function emit() { if (acc != "") { last = acc }; acc = ""; width = 0; joined = 0 }
        {
            line = trim($0)

            if (acc != "") {
                # A continuation of a hard-wrapped URL: URL characters only, no
                # spaces, and never wider than the wrap.
                if (line != "" &&
                    line ~ /^[A-Za-z0-9._~:\/?#@!$&*+,;=%-]+$/ &&
                    line !~ /^https?:\/\// &&
                    (joined == 0 || length(line) <= width)) {
                    # Deciding to join at all is the risky step: an ordinary
                    # word on the line below a URL that happened to end at the
                    # margin is URL-shaped too. A real second fragment either
                    # fills the wrap (the first one may have started part-way
                    # along its line, which is why it can be longer) or still
                    # carries query-string punctuation. A word has neither.
                    if (joined == 0 && length(line) < width && line !~ /[%&=?]/) {
                        emit()
                    } else {
                        # The second fragment is what reveals the true wrap
                        # width when the first one started mid-line.
                        if (joined == 0 && length(line) > width) width = length(line)
                        joined = 1
                        acc = acc line
                        # Short fragment: the wrap ended here, so has the URL.
                        if (length(line) < width || length(acc) > maxlen) emit()
                        next
                    }
                } else {
                    # Not a continuation. Close off the URL and let this line
                    # be considered as the start of a new one.
                    emit()
                }
            }

            if (match(line, /https:\/\/(claude\.(ai|com)|console\.anthropic\.com|platform\.claude\.com)\/[A-Za-z0-9._~:\/?#@!$&*+,;=%-]*/)) {
                acc = substr(line, RSTART, RLENGTH)
                width = RLENGTH
                # Anything after the URL on the same line means the URL ended
                # there of its own accord — nothing to rejoin.
                if (RSTART + RLENGTH - 1 < length(line)) emit()
            }
        }
        END { emit(); if (last != "") print last }
    '
}

# login_url_is_complete — reject a URL that lost its tail.
#
# Claude Code builds the sign-in URL with a PKCE challenge and a state
# parameter appended last, so a whole URL carries both and a truncated one is
# missing at least the state. Anything else (a docs link that happened to be on
# screen) is not a sign-in URL at all and must not be sent as one.
login_url_is_complete() {
    local url="$1"
    [ -n "$url" ] || return 1
    [[ "$url" == *"code_challenge="* ]] || return 1
    [[ "$url" =~ state=[A-Za-z0-9._~%-]{16,} ]] || return 1
    return 0
}

# capture_login_url — pull the sign-in URL out of the Claude tmux session.
# Prints nothing and returns 1 unless a complete URL comes back.
capture_login_url() {
    local session="${1:-claude}" url
    url=$(tmux capture-pane -p -J -t "$session" -S -500 2>/dev/null | login_url_from_text)
    login_url_is_complete "$url" || return 1
    printf '%s\n' "$url"
}
