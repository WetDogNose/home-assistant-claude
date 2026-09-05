#!/bin/bash

# claude-usage — how much Claude Code this add-on has actually used.
#
# Once claude-cron and the Automation API are running prompts unattended, "what
# is this costing me?" stops being idle curiosity: nobody is watching those runs
# and a badly chosen trigger can run Claude all day. Claude Code already records
# per-message token counts in its session transcripts under
# $HOME/.claude/projects; this reads them back.
#
# Deliberately reports TOKENS, not an invented bill. Prices change and are not
# in the transcript, so a hardcoded rate table here would go stale silently and
# be believed anyway. Where Claude Code has written a cost for a message, that
# figure is summed and shown; where it has not, the column stays empty rather
# than being guessed at.
#
# Runs inside the user's terminal — plain bash, no bashio.
#
# Usage:
#   claude-usage [--days N] [--json] [--publish]

set -o pipefail

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME:-/data/home}/.claude/projects}"
DAYS=7
FORMAT="table"
PUBLISH=false

show_help() {
    cat << 'EOF'
claude-usage — token usage from Claude Code's own session transcripts

Usage:
  claude-usage [--days N] [--json] [--publish]

Options:
  --days N     How many days back to report (default 7)
  --json       Machine-readable output
  --publish    Also publish sensor.claude_terminal_tokens_today to Home Assistant
  -h, --help   This help

Notes:
  Figures come from the usage Claude Code records per message in
  $HOME/.claude/projects/*/*.jsonl. Cache reads are counted separately because
  they are the cheap half of a long session and lumping them into "input" makes
  a well-cached day look far more expensive than it was.

  Cost is only shown when Claude Code recorded one. No price table is applied
  here — a stale hardcoded rate would be worse than no number at all.

Examples:
  claude-usage
  claude-usage --days 30
  claude-usage --json | jq '.total'
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --days)
            DAYS="${2:-7}"
            case "$DAYS" in
                ''|*[!0-9]*) echo "Error: --days needs a number." >&2; exit 1 ;;
            esac
            shift 2
            ;;
        --json)    FORMAT="json"; shift ;;
        --publish) PUBLISH=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Error: unknown option '$1'." >&2; show_help; exit 1 ;;
    esac
done

if [ ! -d "$PROJECTS_DIR" ]; then
    if [ "$FORMAT" = "json" ]; then
        echo '{"days": [], "total": {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "messages": 0, "cost_usd": 0}, "note": "no transcripts yet"}'
    else
        echo "No Claude Code transcripts yet (${PROJECTS_DIR} does not exist)."
    fi
    exit 0
fi

# Oldest date to include, as YYYY-MM-DD.
#
# Computed from an epoch offset rather than a relative date string, because the
# image's busybox `date` supports NEITHER of the obvious spellings: `-d "-7
# days"` is rejected (busybox parses only absolute forms and `@epoch`) and `-v`
# is BSD-only. Using them meant both branches failed on Alpine, cutoff fell
# through to "0000-00-00", and `--days` was silently ignored on the only
# platform that matters -- while working on macOS, which is why the tests did
# not catch it. `@epoch` is understood by busybox, GNU and BSD alike.
cutoff=$(date -u -d "@$(( $(date +%s) - DAYS * 86400 ))" +%Y-%m-%d 2>/dev/null \
    || date -u -r "$(( $(date +%s) - DAYS * 86400 ))" +%Y-%m-%d 2>/dev/null \
    || echo "0000-00-00")

# -R reads each line as a raw string so `fromjson?` can skip anything that is
# not a whole JSON object: a transcript being appended to right now has a
# partial final line, and without this the whole report would abort on it.
extract() {
    find "$PROJECTS_DIR" -type f -name '*.jsonl' -print0 2>/dev/null \
        | xargs -0 -r cat 2>/dev/null \
        | jq -R -r '
            fromjson? // empty
            | select(.message.usage != null)
            | [
                ((.timestamp // "") | split("T")[0]),
                (.message.usage.input_tokens // 0),
                (.message.usage.output_tokens // 0),
                (.message.usage.cache_creation_input_tokens // 0),
                (.message.usage.cache_read_input_tokens // 0),
                (.costUSD // 0)
              ]
            | @tsv
        ' 2>/dev/null
}

# Sorting happens in sort(1), not in awk: busybox awk (which is what the image
# has) implements no asorti, so an in-awk sort would silently emit nothing there
# while working perfectly on a development machine.
aggregate() {
    extract | awk -F'\t' -v cutoff="$cutoff" '
        $1 != "" && $1 >= cutoff {
            day[$1] = 1
            inp[$1]  += $2
            out[$1]  += $3
            cw[$1]   += $4
            cr[$1]   += $5
            cost[$1] += $6
            msg[$1]  += 1
        }
        END {
            for (d in day) {
                printf "%s\t%d\t%d\t%d\t%d\t%d\t%.4f\n", d, inp[d], out[d], cw[d], cr[d], msg[d], cost[d]
            }
        }
    ' | sort
}

rows=$(aggregate)

if [ "$FORMAT" = "json" ]; then
    printf '%s\n' "$rows" | jq -R -s --argjson days "$DAYS" '
        [ split("\n")[] | select(length > 0) | split("\t") | {
            date: .[0],
            input: (.[1] | tonumber),
            output: (.[2] | tonumber),
            cache_write: (.[3] | tonumber),
            cache_read: (.[4] | tonumber),
            messages: (.[5] | tonumber),
            cost_usd: (.[6] | tonumber)
        } ] as $rows
        | {
            window_days: $days,
            days: $rows,
            total: {
                input: ([$rows[].input] | add // 0),
                output: ([$rows[].output] | add // 0),
                cache_write: ([$rows[].cache_write] | add // 0),
                cache_read: ([$rows[].cache_read] | add // 0),
                messages: ([$rows[].messages] | add // 0),
                cost_usd: ([$rows[].cost_usd] | add // 0)
            }
        }
    '
else
    echo "=== Claude Code usage (last ${DAYS} days) ==="
    echo ""
    if [ -z "$rows" ]; then
        echo "No usage recorded in this window."
    else
        printf '%-12s %12s %12s %13s %13s %9s %10s\n' \
            "Date" "Input" "Output" "Cache write" "Cache read" "Messages" "Cost USD"
        printf '%s\n' "$rows" | awk -F'\t' '{
            printf "%-12s %12d %12d %13d %13d %9d %10s\n", $1, $2, $3, $4, $5, $6, ($7 > 0 ? sprintf("%.4f", $7) : "-")
        }'
        echo ""
        printf '%s\n' "$rows" | awk -F'\t' '
            { i+=$2; o+=$3; w+=$4; r+=$5; m+=$6; c+=$7 }
            END { printf "%-12s %12d %12d %13d %13d %9d %10s\n", "TOTAL", i, o, w, r, m, (c > 0 ? sprintf("%.4f", c) : "-") }
        '
        echo ""
        echo "Cache reads are billed far below fresh input; they are shown"
        echo "separately so a well-cached day is not mistaken for an expensive one."
    fi
fi

if [ "$PUBLISH" = true ]; then
    today=$(date -u +%Y-%m-%d)
    line=$(printf '%s\n' "$rows" | awk -F'\t' -v d="$today" '$1 == d')
    total_today=$(printf '%s' "$line" | awk -F'\t' '{print $2 + $3}')
    [ -n "$total_today" ] || total_today=0

    if command -v ha-entity >/dev/null 2>&1; then
        attrs=$(printf '%s' "$line" | awk -F'\t' '{
            printf "{\"friendly_name\":\"Claude Terminal Tokens Today\",\"icon\":\"mdi:counter\",\"unit_of_measurement\":\"tokens\",\"state_class\":\"total_increasing\",\"input\":%d,\"output\":%d,\"cache_write\":%d,\"cache_read\":%d,\"messages\":%d}", $2, $3, $4, $5, $6
        }')
        [ -n "$attrs" ] || attrs='{"friendly_name":"Claude Terminal Tokens Today","icon":"mdi:counter","unit_of_measurement":"tokens","state_class":"total_increasing"}'
        ha-entity publish sensor.claude_terminal_tokens_today "$total_today" "$attrs" \
            && echo "Published sensor.claude_terminal_tokens_today = ${total_today}" \
            || echo "Could not publish to Home Assistant." >&2
    else
        echo "ha-entity is not available; nothing published." >&2
    fi
fi
