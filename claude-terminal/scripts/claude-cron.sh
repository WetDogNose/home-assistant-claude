#!/bin/bash

# claude-cron — run Claude on a schedule, with nobody watching.
#
# Runs inside the user's terminal as well as as a daemon — plain bash, no
# bashio (ttyd's environment does not provide it); add-on options are read
# straight out of /data/options.json.
#
# Three things about this file are load-bearing:
#
# 1. Jobs run with the SAME flags an interactive session gets. This used to
#    invoke a bare `claude -p "$prompt"`, ignoring dangerously_skip_permissions
#    and claude_extra_args while the Automation API applied both — so the
#    identical prompt could do its job through an automation and quietly refuse
#    to touch anything on a schedule. A scheduled job has nobody to answer a
#    permission prompt, which makes it the case that needs the flags most.
#
# 2. Every write to the job file goes through json_update, which locks. The
#    daemon and the CLI write the same file, and a read-modify-write from both
#    at once loses one of them: adding a job from the terminal while a job was
#    running used to discard the new job with no error anywhere.
#
# 3. Jobs set CLAUDE_TERMINAL_NO_HOOK_NOTIFY, so Claude Code's Stop hook stays
#    quiet for them. Without it every scheduled run notifies twice — once from
#    the hook and once from here, with different wording.

set -o pipefail

CRON_FILE="${CRON_FILE:-/data/claude-cron.json}"
LOG_FILE="${CRON_LOG_FILE:-/data/claude-cron.log}"
OUTPUT_DIR="${CRON_OUTPUT_DIR:-/data/claude-cron-last}"
OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"

# /data rides along in Home Assistant backups, so nothing here may grow without
# a ceiling. The log is trimmed to this many lines after every run, and only the
# most recent output per job is kept.
LOG_MAX_LINES="${CRON_LOG_MAX_LINES:-400}"
OUTPUT_MAX_BYTES="${CRON_OUTPUT_MAX_BYTES:-16384}"

DEFAULT_DOC='{"jobs": []}'

# setup_commands COPIES this script to /usr/local/bin/claude-cron, so the
# library is not beside the running copy. Same lookup as claude-login-url.sh.
LIB=""
for candidate in "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/state-lib.sh" \
                 /opt/scripts/state-lib.sh; do
    if [ -f "$candidate" ]; then LIB="$candidate"; break; fi
done
if [ -z "$LIB" ]; then
    echo "claude-cron: state-lib.sh not found." >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$LIB"

show_help() {
    cat << 'EOF'
claude-cron — scheduled Claude tasks for Claude Terminal

Usage:
  claude-cron list                          Show scheduled jobs
  claude-cron add "<schedule>" "<prompt>"   Add a job
  claude-cron remove <id>                   Delete a job
  claude-cron enable <id>                   Resume a paused job
  claude-cron disable <id>                  Pause a job without deleting it
  claude-cron run <id>                      Run a job now, in the foreground
  claude-cron log [id]                      Show recent runs
  claude-cron output <id>                   Show a job's most recent output
  claude-cron daemon                        The scheduler loop (started by the add-on)

Schedules:
  "30"                 every 30 minutes (the old form, still accepted)
  "every 30m"          every 30 minutes
  "every 6h"           every 6 hours
  "every 2d"           every 2 days
  "daily 03:15"        at 03:15 every day
  "0 3 * * *"          standard five-field cron (minute hour day month weekday)
  "*/15 8-22 * * 1-5"  every 15 minutes, 8am-10pm, weekdays

  Cron and "daily" schedules run in the add-on's local time, which is the
  timezone Home Assistant passes in. "every N" schedules count from the last
  run, so they drift by however long a job takes — which is what you want for
  "check every so often" and not what you want for "report at 7am".

Jobs run with the same permission flags an interactive session gets, taken from
the add-on options. A job that needs to change something will need
dangerously_skip_permissions, because there is nobody there to approve it.

Examples:
  claude-cron add "daily 07:00" "Summarise yesterday's energy use and notify me"
  claude-cron add "0 */4 * * *" "Check every battery sensor and flag any under 20%"
  claude-cron add "every 30m" "Check whether the garage door has been left open"
  claude-cron disable 2
  claude-cron log 2
EOF
}

# --------------------------------------------------------------- options ----

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

# The flags every scheduled run gets. Mirrors build_claude_flags in run.sh and
# the same block in claude-api-server.py; all three read the same two options,
# and a job behaving differently from an automation behaving differently from
# the terminal is exactly the confusion this avoids.
claude_flags() {
    local flags=()
    [ "$(option dangerously_skip_permissions false)" = "true" ] && flags+=("--dangerously-skip-permissions")

    local extra
    extra=$(option claude_extra_args "")
    if [ -n "$extra" ]; then
        # Word-split deliberately: same documented limitation as claude_extra_args
        # everywhere else in the add-on (quoted multi-word values are not
        # re-parsed).
        # shellcheck disable=SC2206
        flags+=($extra)
    fi
    printf '%s\n' "${flags[@]+"${flags[@]}"}"
}

# -------------------------------------------------------------- schedules ----

# Split a string into SPLIT_RESULT without pathname expansion.
#
# Every schedule field here can be a literal "*", and unquoted word splitting
# also runs globbing -- so "0 3 * * *" splits into the contents of the working
# directory, which is /config for a scheduled job. The symptom is not an error:
# the fields simply stop matching and the job never fires, from a directory that
# happens to be non-empty. Every split of a schedule goes through this.
SPLIT_RESULT=()
safe_split() {
    local sep="$1" text="$2" restore_glob
    case "$-" in *f*) restore_glob="set -f" ;; *) restore_glob="set +f" ;; esac
    set -f
    local IFS="$sep"
    # shellcheck disable=SC2206
    SPLIT_RESULT=($text)
    unset IFS
    $restore_glob
}

# Normalise what the user typed into one of two internal forms:
#   "interval <seconds>"  — count from the last run
#   "cron <m> <h> <dom> <mon> <dow>"
# Anything else is rejected at `add` time rather than silently never firing,
# which is how a typo in a schedule usually announces itself.
parse_schedule() {
    local spec="$1" n unit

    # Bare minutes: the original schedule format. Still accepted so upgrading
    # does not invalidate anyone's existing jobs.
    #
    # 10# is required, not decorative: "08" and "09" pass the digit filter and
    # are then read as invalid octal by bash arithmetic, which is a FATAL
    # expansion error -- `claude-cron add "08" "..."` died with a raw bash
    # message and added nothing.
    case "$spec" in
        ''|*[!0-9]*) ;;
        *)
            [ "$((10#$spec))" -gt 0 ] || return 1
            echo "interval $((10#$spec * 60))"
            return 0
            ;;
    esac

    case "$spec" in
        "every "*)
            n=${spec#every }
            n=${n// /}
            unit="${n: -1}"
            n="${n%?}"
            case "$n" in ''|*[!0-9]*) return 1 ;; esac
            [ "$n" -gt 0 ] || return 1
            case "$unit" in
                m) echo "interval $((n * 60))" ;;
                h) echo "interval $((n * 3600))" ;;
                d) echo "interval $((n * 86400))" ;;
                *) return 1 ;;
            esac
            return 0
            ;;
        "daily "*)
            n=${spec#daily }
            n=${n// /}
            case "$n" in
                [0-9][0-9]:[0-9][0-9])
                    local hh mm
                    hh=${n%%:*}; mm=${n##*:}
                    # Strip leading zeros before the range check: 08 is octal to
                    # bash's arithmetic and would be a syntax error, not an 8.
                    hh=$((10#$hh)); mm=$((10#$mm))
                    [ "$hh" -le 23 ] && [ "$mm" -le 59 ] || return 1
                    echo "cron ${mm} ${hh} * * *"
                    return 0
                    ;;
                *) return 1 ;;
            esac
            ;;
    esac

    # Five-field cron.
    safe_split ' ' "$spec"
    if [ "${#SPLIT_RESULT[@]}" -eq 5 ]; then
        local f
        for f in "${SPLIT_RESULT[@]}"; do
            # Named months and weekdays (JAN, MON) are rejected rather than
            # accepted-and-ignored: a field the matcher cannot understand would
            # otherwise match nothing and the job would never fire, with no
            # error to explain why.
            case "$f" in
                ''|*[!0-9,/*-]*) return 1 ;;
            esac
        done
        echo "cron ${SPLIT_RESULT[0]} ${SPLIT_RESULT[1]} ${SPLIT_RESULT[2]} ${SPLIT_RESULT[3]} ${SPLIT_RESULT[4]}"
        return 0
    fi

    return 1
}

# Does one cron field match one value?
#
# Handles *, */step, a-b, a-b/step and comma-separated lists of those, which is
# the whole of what a five-field crontab can express for these purposes. Named
# months and weekdays are not supported and are rejected by parse_schedule, so
# they cannot reach here and silently never match.
cron_field_matches() {
    local spec="$1" value="$2" lo="$3" hi="$4"
    local part start end step i

    safe_split ',' "$spec"
    local parts=("${SPLIT_RESULT[@]}")

    for part in "${parts[@]}"; do
        step=1
        case "$part" in
            */*)
                step="${part##*/}"
                part="${part%%/*}"
                ;;
        esac
        case "$step" in ''|*[!0-9]*) continue ;; esac
        [ "$step" -gt 0 ] || continue

        if [ "$part" = "*" ]; then
            start="$lo"; end="$hi"
        else
            case "$part" in
                *-*)
                    start="${part%%-*}"
                    end="${part##*-}"
                    ;;
                *)
                    start="$part"
                    end="$part"
                    ;;
            esac
        fi

        case "$start$end" in ''|*[!0-9]*) continue ;; esac
        start=$((10#$start)); end=$((10#$end))
        [ "$start" -le "$end" ] || continue

        i="$start"
        while [ "$i" -le "$end" ]; do
            if [ "$i" -eq "$value" ]; then
                return 0
            fi
            i=$((i + step))
        done
    done
    return 1
}

# Day-of-week, accepting 7 as Sunday alongside 0 (both are standard crontab).
# The upper bound is 7 rather than 6 so that "*/2" and ranges ending at 7 expand
# the way a crontab reader expects.
dow_matches_now() {
    local spec="$1"
    cron_field_matches "$spec" "$now_dow" 0 7 && return 0
    [ -n "$now_dow_alt" ] && cron_field_matches "$spec" "$now_dow_alt" 0 7 && return 0
    return 1
}

# Is a "cron m h dom mon dow" schedule due at the current minute?
cron_due_now() {
    local m="$1" h="$2" dom="$3" mon="$4" dow="$5"
    local now_m now_h now_dom now_mon now_dow

    now_m=$((10#$(date +%M)))
    now_h=$((10#$(date +%H)))
    now_dom=$((10#$(date +%d)))
    now_mon=$((10#$(date +%m)))
    now_dow=$((10#$(date +%w)))

    # Standard crontab allows 7 for Sunday as well as 0, and `date +%w` only
    # ever emits 0-6 -- so "0 3 * * 7" was accepted by `add` and then matched
    # nothing, for ever, with no error. That is precisely the failure this file
    # rejects named weekdays to avoid. Ranges like 1-7 lost Sunday the same way.
    local now_dow_alt=""
    [ "$now_dow" = "0" ] && now_dow_alt=7

    cron_field_matches "$m"   "$now_m"   0 59 || return 1
    cron_field_matches "$h"   "$now_h"   0 23 || return 1
    cron_field_matches "$mon" "$now_mon" 1 12 || return 1

    # Real cron ORs day-of-month and day-of-week when both are restricted, and
    # ANDs them when only one is. Reproduced rather than simplified, because
    # "0 3 1 * 1" meaning "the 1st OR any Monday" is a genuine crontab idiom and
    # silently narrowing it to AND would make such a job fire roughly never.
    local dom_restricted=false dow_restricted=false
    [ "$dom" != "*" ] && dom_restricted=true
    [ "$dow" != "*" ] && dow_restricted=true

    if [ "$dom_restricted" = true ] && [ "$dow_restricted" = true ]; then
        cron_field_matches "$dom" "$now_dom" 1 31 && return 0
        dow_matches_now "$dow" && return 0
        return 1
    fi

    cron_field_matches "$dom" "$now_dom" 1 31 || return 1
    dow_matches_now "$dow" || return 1
    return 0
}

# A job's schedule, whatever era it was written in. Jobs created before
# schedules existed carry interval_min and no schedule field; they keep working
# rather than being migrated in place, so downgrading the add-on does not strand
# them.
job_schedule() {
    local job="$1" schedule interval
    schedule=$(printf '%s' "$job" | jq -r '.schedule // empty')
    if [ -n "$schedule" ]; then
        printf '%s' "$schedule"
        return 0
    fi
    interval=$(printf '%s' "$job" | jq -r '.interval_min // empty')
    [ -n "$interval" ] && printf 'every %sm' "$interval"
}

job_due() {
    local job="$1" now="$2" schedule parsed last kind
    schedule=$(job_schedule "$job")
    [ -n "$schedule" ] || return 1

    parsed=$(parse_schedule "$schedule") || return 1
    kind=${parsed%% *}
    last=$(printf '%s' "$job" | jq -r '.last_timestamp // 0')
    case "$last" in ''|*[!0-9]*) last=0 ;; esac

    if [ "$kind" = "interval" ]; then
        local seconds=${parsed#interval }
        [ $((now - last)) -ge "$seconds" ]
        return $?
    fi

    # Cron: the daemon wakes once a minute, so guard against a second firing
    # inside the same minute if a tick runs long or the clock steps back.
    [ $((now - last)) -ge 60 ] || return 1

    safe_split ' ' "${parsed#cron }"
    cron_due_now "${SPLIT_RESULT[0]}" "${SPLIT_RESULT[1]}" "${SPLIT_RESULT[2]}" \
                 "${SPLIT_RESULT[3]}" "${SPLIT_RESULT[4]}"
}

# ------------------------------------------------------------------ jobs ----

init_file() {
    mkdir -p "$(dirname "$CRON_FILE")" 2>/dev/null || true
    [ -s "$CRON_FILE" ] || printf '%s\n' "$DEFAULT_DOC" > "$CRON_FILE"
}

cmd_list() {
    init_file
    echo "=== Claude Terminal scheduled jobs ==="
    local count
    count=$(json_read "$CRON_FILE" "$DEFAULT_DOC" '.jobs | length')
    if [ "${count:-0}" -eq 0 ]; then
        echo "(nothing scheduled — try: claude-cron add \"daily 07:00\" \"...\")"
        return 0
    fi

    # `.enabled // true` would be WRONG here and everywhere else in this file:
    # jq's // returns its right side for false as well as for null, so a paused
    # job reads back as enabled. Every boolean default below is written as an
    # explicit comparison for that reason -- the daemon shares this test, and
    # there the bug was not a missing label but a paused job that kept running.
    json_read "$CRON_FILE" "$DEFAULT_DOC" '
        .jobs[]
        | "[\(.id)] \(if .enabled == false then "(paused) " else "" end)\(.schedule // "every \(.interval_min)m")\n"
        + "     \(.prompt)\n"
        + "     last: \(.last_run // "never")\(if .last_status then " (\(.last_status)\(if .last_duration then ", \(.last_duration)s" else "" end))" else "" end)"
    '
}

cmd_add() {
    init_file
    local schedule="${1:-}" prompt="${2:-}"

    if [ -z "$schedule" ] || [ -z "$prompt" ]; then
        echo "Error: need a schedule and a prompt." >&2
        echo "Try: claude-cron add \"daily 07:00\" \"Summarise yesterday's energy use\"" >&2
        return 1
    fi

    if ! parse_schedule "$schedule" >/dev/null; then
        echo "Error: '${schedule}' is not a schedule I understand." >&2
        echo "Use minutes (\"30\"), \"every 30m\" / \"every 6h\" / \"every 2d\", \"daily HH:MM\"," >&2
        echo "or five-field cron (\"0 3 * * *\"). See claude-cron --help." >&2
        return 1
    fi

    # The new id is chosen inside the same locked update that appends the job,
    # so two `add`s at once cannot both pick the same one.
    json_update "$CRON_FILE" "$DEFAULT_DOC" \
        --arg schedule "$schedule" --arg prompt "$prompt" '
        ((.jobs | map(.id) | max // 0) + 1) as $id
        | .jobs += [{
            id: $id,
            schedule: $schedule,
            prompt: $prompt,
            enabled: true,
            notify: true,
            last_run: null,
            last_timestamp: 0,
            last_status: null,
            last_duration: null
          }]
    ' || {
        echo "Error: could not write ${CRON_FILE}." >&2
        return 1
    }

    local new_id
    new_id=$(json_read "$CRON_FILE" "$DEFAULT_DOC" '.jobs | map(.id) | max')
    echo "Added job [${new_id}]: ${schedule} — \"${prompt}\""

    if [ "$(option dangerously_skip_permissions false)" != "true" ]; then
        echo ""
        echo "Note: dangerously_skip_permissions is off, so this job can read and report"
        echo "but will refuse changes it would normally ask you to approve. There is"
        echo "nobody to ask on a schedule."
    fi
}

cmd_remove() {
    init_file
    local job_id="${1:-}"
    case "$job_id" in
        ''|*[!0-9]*) echo "Error: which job? Try 'claude-cron list'." >&2; return 1 ;;
    esac

    local exists
    exists=$(json_read "$CRON_FILE" "$DEFAULT_DOC" --argjson id "$job_id" '[.jobs[] | select(.id == $id)] | length')
    if [ "${exists:-0}" -eq 0 ]; then
        echo "Error: no job [${job_id}]." >&2
        return 1
    fi

    json_update "$CRON_FILE" "$DEFAULT_DOC" --argjson id "$job_id" '.jobs |= map(select(.id != $id))' \
        || { echo "Error: could not write ${CRON_FILE}." >&2; return 1; }
    rm -f "${OUTPUT_DIR}/${job_id}.txt" 2>/dev/null || true
    echo "Removed job [${job_id}]."
}

set_enabled() {
    init_file
    local job_id="${1:-}" enabled="$2" word="$3"
    case "$job_id" in
        ''|*[!0-9]*) echo "Error: which job? Try 'claude-cron list'." >&2; return 1 ;;
    esac

    local exists
    exists=$(json_read "$CRON_FILE" "$DEFAULT_DOC" --argjson id "$job_id" '[.jobs[] | select(.id == $id)] | length')
    if [ "${exists:-0}" -eq 0 ]; then
        echo "Error: no job [${job_id}]." >&2
        return 1
    fi

    json_update "$CRON_FILE" "$DEFAULT_DOC" \
        --argjson id "$job_id" --argjson enabled "$enabled" \
        '.jobs |= map(if .id == $id then .enabled = $enabled else . end)' \
        || { echo "Error: could not write ${CRON_FILE}." >&2; return 1; }
    echo "Job [${job_id}] ${word}."
}

# ------------------------------------------------------------- execution ----

log_line() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || return 0

    # Trim in place rather than rotating: a second file would double what a
    # Home Assistant backup carries for no benefit anyone asked for.
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "${lines:-0}" -gt "$LOG_MAX_LINES" ]; then
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null \
            && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

publish_state() {
    command -v ha-entity >/dev/null 2>&1 || return 0
    ha-entity set "$@" >/dev/null 2>&1 || true
}

# Run one job. Returns the claude exit code; never aborts the daemon.
execute_job() {
    local job_id="$1" prompt="$2" notify="$3"
    local started ended duration status output rc=0
    local flags=()

    while IFS= read -r flag; do
        [ -n "$flag" ] && flags+=("$flag")
    done < <(claude_flags)

    started=$(date +%s)
    publish_state busy=true status=running last_source=cron

    mkdir -p "$OUTPUT_DIR" 2>/dev/null || true

    # CLAUDE_TERMINAL_NO_HOOK_NOTIFY: Claude Code's Stop hook fires for `-p`
    # runs too, so without this every scheduled job would notify twice.
    output=$(CLAUDE_TERMINAL_NO_HOOK_NOTIFY=1 claude -p "$prompt" ${flags[@]+"${flags[@]}"} 2>&1) || rc=$?

    ended=$(date +%s)
    duration=$((ended - started))
    status=$([ "$rc" -eq 0 ] && echo "ok" || echo "error")

    # Only the latest output per job is kept, capped: /data is backed up, and an
    # hourly job left running for a month is otherwise an unbounded write.
    printf '%s\n' "$output" | head -c "$OUTPUT_MAX_BYTES" > "${OUTPUT_DIR}/${job_id}.txt" 2>/dev/null || true

    json_update "$CRON_FILE" "$DEFAULT_DOC" \
        --argjson id "$job_id" --argjson ts "$ended" \
        --arg date "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
        --arg status "$status" --argjson duration "$duration" '
        .jobs |= map(
            if .id == $id then
                .last_timestamp = $ts
                | .last_run = $date
                | .last_status = $status
                | .last_duration = $duration
            else . end
        )
    ' || true

    publish_state busy=false status=idle "last_result=${status}" last_source=cron \
        "last_run=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"

    log_line "job[${job_id}] ${status} in ${duration}s: $(printf '%s' "$output" | head -c 200 | tr '\n' ' ')"

    if [ "$notify" != "false" ] && command -v ha-notify >/dev/null 2>&1; then
        local message
        message=$(printf '%s' "$output" | head -c 800)
        [ -n "$message" ] || message="(no output)"
        [ "$status" = "error" ] && message="Job failed after ${duration}s.

${message}"
        ha-notify "Claude scheduled job [${job_id}]" "$message" "claude_terminal_cron_${job_id}" || true
    fi

    printf '%s' "$output"
    return "$rc"
}

cmd_run() {
    init_file
    local job_id="${1:-}"
    case "$job_id" in
        ''|*[!0-9]*) echo "Error: which job? Try 'claude-cron list'." >&2; return 1 ;;
    esac

    local job prompt notify
    job=$(json_read "$CRON_FILE" "$DEFAULT_DOC" -c --argjson id "$job_id" '.jobs[] | select(.id == $id)')
    if [ -z "$job" ]; then
        echo "Error: no job [${job_id}]." >&2
        return 1
    fi

    prompt=$(printf '%s' "$job" | jq -r '.prompt')
    notify=$(printf '%s' "$job" | jq -r 'if .notify == false then "false" else "true" end')

    echo "Running job [${job_id}] now..."
    echo ""
    execute_job "$job_id" "$prompt" "$notify"
}

cmd_log() {
    local job_id="${1:-}"
    if [ ! -s "$LOG_FILE" ]; then
        echo "No runs recorded yet."
        return 0
    fi
    if [ -n "$job_id" ]; then
        grep "job\[${job_id}\]" "$LOG_FILE" | tail -n 40
    else
        tail -n 40 "$LOG_FILE"
    fi
}

cmd_output() {
    local job_id="${1:-}"
    case "$job_id" in
        ''|*[!0-9]*) echo "Error: which job? Try 'claude-cron list'." >&2; return 1 ;;
    esac
    if [ -s "${OUTPUT_DIR}/${job_id}.txt" ]; then
        cat "${OUTPUT_DIR}/${job_id}.txt"
    else
        echo "No output recorded for job [${job_id}] yet."
    fi
}

cmd_daemon() {
    init_file
    log_line "daemon started"

    while true; do
        # Wake on the minute rather than every 60s from an arbitrary start.
        # Cron schedules match a minute, so a loop that drifts a few seconds per
        # tick eventually steps over one entirely and a "0 3 * * *" job silently
        # skips a day.
        sleep $(( 60 - 10#$(date +%S) ))   # 10# — "08" is octal to bash arithmetic

        local now jobs job job_id prompt notify enabled
        now=$(date +%s)
        jobs=$(json_read "$CRON_FILE" "$DEFAULT_DOC" -c '.jobs[]?' 2>/dev/null)
        [ -n "$jobs" ] || continue

        while IFS= read -r job; do
            [ -n "$job" ] || continue
            enabled=$(printf '%s' "$job" | jq -r 'if .enabled == false then "false" else "true" end')
            [ "$enabled" = "true" ] || continue

            job_due "$job" "$now" || continue

            job_id=$(printf '%s' "$job" | jq -r '.id')
            prompt=$(printf '%s' "$job" | jq -r '.prompt')
            notify=$(printf '%s' "$job" | jq -r 'if .notify == false then "false" else "true" end')

            log_line "job[${job_id}] starting: $(printf '%s' "$prompt" | head -c 120)"
            execute_job "$job_id" "$prompt" "$notify" >/dev/null 2>&1 || true
        done <<< "$jobs"
    done
}

case "${1:-}" in
    list|ls)   cmd_list ;;
    add)       cmd_add "${2:-}" "${3:-}" ;;
    remove|rm) cmd_remove "${2:-}" ;;
    enable)    set_enabled "${2:-}" true "resumed" ;;
    disable)   set_enabled "${2:-}" false "paused" ;;
    run)       cmd_run "${2:-}" ;;
    log)       cmd_log "${2:-}" ;;
    output)    cmd_output "${2:-}" ;;
    daemon)    cmd_daemon ;;
    -h|--help|help) show_help ;;
    *)         show_help ;;
esac
