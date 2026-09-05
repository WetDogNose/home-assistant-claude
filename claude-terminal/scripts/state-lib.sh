#!/bin/bash
# state-lib.sh — atomic JSON state helpers, sourced by the scripts that share
# files under /data.
#
# Not a command: nothing here is meant to be executed directly, so
# `setup_commands` does not install it and `ci/smoke.sh` checks for it in the
# "sourced libraries" list instead. Same arrangement as login-url-lib.sh.
#
# Why this exists: claude-cron's daemon and its CLI write the same job file, and
# both used to do a read-modify-write with no lock at all -- `jq ... "$FILE" >
# tmp` from two processes loses whichever write lands first. Adding a job from
# the terminal while a job was running silently discarded the new job. ha-entity
# has the same shape (several publishers, one state file), so the fix lives
# here rather than twice.
#
# The lock is a mkdir, not flock: flock is a busybox applet in the image but is
# absent on macOS, where tests/test_scripts.sh runs. mkdir is atomic on every
# POSIX filesystem and needs no external binary.

# Seconds a lock may be held before it is assumed to belong to a dead process.
# Longer than any write here takes (all are sub-second jq runs) and shorter
# than a user would wait before deciding the command has hung.
STATE_LOCK_STALE_SECONDS="${STATE_LOCK_STALE_SECONDS:-30}"
STATE_LOCK_WAIT_SECONDS="${STATE_LOCK_WAIT_SECONDS:-10}"

# Portable mtime in epoch seconds, or empty when the path cannot be stat'ed.
# GNU and BSD stat disagree on the flag and the image has neither -- it has
# busybox stat, which follows GNU. Try both.
#
# Returning EMPTY rather than 0 for "cannot stat" is load-bearing: see
# state_lock, where treating an unreadable lock as timestamp 0 made it look
# infinitely old.
_state_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Tenths of a second between attempts. Whole-second retries are too coarse:
# a dozen writers each waiting a second would exhaust the wait budget and start
# failing, even though every one of these critical sections is a sub-second jq.
_STATE_RETRY_TENTHS=1

# Acquire <lockdir>. Waits up to STATE_LOCK_WAIT_SECONDS, then breaks a lock
# older than STATE_LOCK_STALE_SECONDS and takes it: a daemon killed mid-write
# (a container restart is exactly that) must not wedge the CLI forever.
state_lock() {
    local lockdir="$1" attempts=0 max_attempts mtime now
    max_attempts=$(( STATE_LOCK_WAIT_SECONDS * 10 / _STATE_RETRY_TENTHS ))

    while ! mkdir "$lockdir" 2>/dev/null; do
        mtime=$(_state_mtime "$lockdir")

        # An unreadable lock means the holder released it between our mkdir
        # failing and this stat -- NOT that the lock is ancient. Reading it as
        # "infinitely old" is what let a waiter rmdir a lock another process had
        # just taken; both then believed they held it, ran their
        # read-modify-write concurrently, and one update was silently lost.
        # Falling through to a retry is correct: the next mkdir usually wins.
        if [ -n "$mtime" ]; then
            now=$(date +%s)
            if [ "$(( now - mtime ))" -ge "$STATE_LOCK_STALE_SECONDS" ]; then
                # Try to break it, then fall through to the SAME wait
                # accounting as any other retry. An early `continue` here span
                # the loop with no sleep and no attempt counter whenever the
                # rmdir could not succeed -- a lock path that is a regular file,
                # a non-empty directory, or /data gone read-only. The wait
                # budget was then never consulted, so `ha-entity set` on the
                # boot path could hang for ever at 100% of a core and the
                # terminal would never open.
                rmdir "$lockdir" 2>/dev/null || true
            fi
        fi

        attempts=$((attempts + 1))
        if [ "$attempts" -ge "$max_attempts" ]; then
            return 1
        fi
        sleep "0.${_STATE_RETRY_TENTHS}"
    done
    return 0
}

state_unlock() {
    rmdir "$1" 2>/dev/null || true
}

# json_update <file> <default_json> [jq options...] <filter>
# json_read   <file> <default_json> [jq options...] <filter>
#
# The filter comes LAST, and jq's own options come before it, so a call reads
# the way the equivalent jq command line does:
#
#     json_update "$f" '{}' --argjson id 3 '.jobs |= map(select(.id != $id))'
#
# The alternative -- filter third, options after -- was tried and is a trap:
# `json_read "$f" "$d" --argjson id 3 '<filter>'` then silently runs jq with
# "--argjson" AS the filter, which fails, which falls back to the default
# document, which reports every existing job as missing.

_json_split_args() {
    # Sets _JSON_FILTER to the last argument and _JSON_OPTS to everything
    # before it.
    _JSON_FILTER="${!#}"
    _JSON_OPTS=("${@:1:$#-1}")
}

# Read-modify-write under the file's lock, via a temp file in the same
# directory and an mv. The mv is what makes a reader either see the whole old
# document or the whole new one: writing in place leaves a window where the
# file is truncated, and every reader here is a `jq` that would fail on it.
#
# A jq failure leaves the original untouched -- the temp file is discarded
# rather than moved -- so a bad filter cannot destroy the job list.
json_update() {
    local file="$1" default="$2"
    shift 2
    local _JSON_FILTER _JSON_OPTS
    _json_split_args "$@"

    local lockdir="${file}.lock" tmp rc=0

    mkdir -p "$(dirname "$file")" 2>/dev/null || true

    state_lock "$lockdir" || {
        echo "state-lib: could not lock ${file}" >&2
        return 1
    }

    # Seeding the file happens INSIDE the lock. Doing it before meant several
    # writers starting at once could each see an empty file and each write the
    # default over the top of a document another had already committed.
    [ -s "$file" ] || printf '%s\n' "$default" > "$file"

    tmp="${file}.tmp.$$"
    if jq ${_JSON_OPTS[@]+"${_JSON_OPTS[@]}"} "$_JSON_FILTER" "$file" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$file"
    else
        rc=1
        rm -f "$tmp"
    fi

    state_unlock "$lockdir"
    return "$rc"
}

# Reads without taking the lock: json_update publishes by rename, so a reader
# always has a complete document open. Falls back to the default when the file
# is missing or unparseable, because every caller here would rather report
# "nothing scheduled" than abort.
json_read() {
    local file="$1" default="$2"
    shift 2
    local _JSON_FILTER _JSON_OPTS
    _json_split_args "$@"

    if [ -s "$file" ]; then
        jq -r ${_JSON_OPTS[@]+"${_JSON_OPTS[@]}"} "$_JSON_FILTER" "$file" 2>/dev/null && return 0
    fi
    printf '%s\n' "$default" | jq -r ${_JSON_OPTS[@]+"${_JSON_OPTS[@]}"} "$_JSON_FILTER" 2>/dev/null
}
