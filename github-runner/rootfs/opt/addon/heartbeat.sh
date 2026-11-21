#!/bin/bash
# Publish sensor.github_runner_heartbeat every 5 minutes while the runner's
# listener is alive. Home Assistant forgets REST-created states on restart, so
# a one-shot publish would go quiet after the first HA restart; the loop is
# what makes the entity durable. Alert on staleness in Home Assistant.
set -u

while true; do
  if pgrep -f 'Runner\.Listener' >/dev/null; then
    body=$(jq -nc --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
      state: $now,
      attributes: {
        device_class: "timestamp",
        friendly_name: "GitHub runner heartbeat",
        icon: "mdi:heart-pulse"
      }}')
    curl -fsS -o /dev/null -X POST \
      -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
      -H "Content-Type: application/json" \
      -d "$body" \
      http://supervisor/core/api/states/sensor.github_runner_heartbeat \
      || echo "[github-runner] heartbeat publish failed"
  fi
  sleep 300
done
