#!/bin/bash

# ha-notify — raise a Home Assistant persistent notification.
#
# The add-on's failure modes are currently invisible: a broken login, a failed
# package install or an unrunnable Claude build are all reported to the add-on
# log, which is a place nobody looks until they already suspect a problem. Home
# Assistant has a notification drawer the user is actually looking at.
#
# Usage: ha-notify <title> <message> [notification-id]
#
# Safe to call from anywhere: it no-ops without SUPERVISOR_TOKEN, never blocks
# for more than a few seconds, and never returns non-zero into a caller's
# `set -e`.

set -o pipefail

title="${1:-Claude Terminal}"
message="${2:-}"
notify_id="${3:-claude_terminal}"

[ -n "$message" ] || exit 0
[ -n "${SUPERVISOR_TOKEN:-}" ] || exit 0

payload=$(jq -nc \
    --arg t "$title" --arg m "$message" --arg i "$notify_id" \
    '{title: $t, message: $m, notification_id: $i}') || exit 0

curl -fsS -m 10 -o /dev/null \
    -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "http://supervisor/core/api/services/persistent_notification/create" \
    2>/dev/null || true

exit 0
