---
name: ha-diagnostics
description: Investigate why something in Home Assistant is broken, slow, offline or misbehaving, using this add-on's built-in inspectors — ha-diagnose for a whole-system report, ha-mesh for Zigbee/Z-Wave/Matter radio and battery health, and claude-doctor for the add-on's own environment. Use this whenever the user reports that a device, sensor, integration or automation stopped working, went unavailable, is unresponsive, dropped off the network, has a flat battery, or that Home Assistant itself feels slow, is throwing errors, or won't start. Also use it for open-ended health checks — "is everything OK?", "anything I should look at?", "why is my Zigbee flaky?" — and reach for it before guessing at causes, because these commands answer in seconds what would otherwise be a long manual API crawl.
---

# Diagnosing a Home Assistant instance

Start from evidence rather than hypotheses. Three commands cover most of the
ground, and each answers a different question.

## Pick the right starting point

| Symptom | Start with |
|---|---|
| "Something's wrong" / no specific symptom | `ha-diagnose` |
| A device is unavailable, unresponsive, dropping out | `ha-mesh` |
| Batteries, low battery warnings | `ha-mesh` |
| Home Assistant won't reload / restart, YAML suspected | `ha-validate` (see the ha-config-safety skill) |
| Claude itself misbehaving — login, network, MCP, updates | `claude-doctor` |
| "When did it stop?" / "how long has it been like this?" | `ha-memory` (see the ha-history skill) |

## ha-diagnose — the whole-instance report

```bash
ha-diagnose
```

Prints a Markdown report with five sections: container environment (home, user,
memory, `/config` disk usage), the result of a live `ha-validate` config check,
an entity count per domain, the last 10 error/warning lines from
`/config/home-assistant.log`, and whether the Automation API and `claude-cron`
daemons are running.

Read it as a triage sheet, not a verdict. What it is good at is telling you
*which* of the five areas deserves the next question — a failing config check
sends you to the config-safety flow, a full disk explains a database that
stopped recording, a stopped Automation API explains automations that silently
do nothing.

`/config/home-assistant.log` is only the tail of what Home Assistant recorded to
disk. For the live, complete log, ask Core directly:

```bash
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  http://supervisor/core/api/error_log | tail -100
```

## ha-mesh — radio and battery health

```bash
ha-mesh
```

Three sections, all derived from current entity states:

1. **Low battery (<20%)** — any entity with `device_class: battery` or an id
   ending `_battery`. This is the single most common cause of a device that
   "stopped responding" — a battery sensor at 3% is the answer, not a symptom.
2. **Unavailable / unknown entities** — capped at the first 15, with a count of
   the rest. A handful is normal (a device asleep, an integration still
   starting). Dozens at once usually means one *coordinator* died — the Zigbee
   or Z-Wave stick, or an integration that lost its cloud connection — not
   dozens of independent failures. Look for the common prefix before treating
   them as separate problems.
3. **Signal quality (LQI / RSSI)** — first 15 entities exposing those
   attributes. Low LQI on a mains-powered device that should be a router
   suggests a routing problem worth reporting; many mesh devices never expose
   these attributes at all, so an empty section is not a fault.

## claude-doctor — this add-on's own environment

```bash
claude-doctor
```

Checks the terminal's environment rather than Home Assistant's: network reach,
Claude authentication state, the persistent install under
`/data/home/.local/bin`, and the MCP configuration. Use it when the problem is
Claude — a failed login, an update that did not take, an MCP server that is not
answering — rather than when a light won't turn on.

## Digging past the summaries

The reports are deliberately shallow. When one points at something, go to the
API for detail:

```bash
# Everything currently unavailable, with friendly names
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states \
  | jq -r '.[] | select(.state=="unavailable") | "\(.entity_id)\t\(.attributes.friendly_name // "")"'

# Full state and attributes of one entity
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  http://supervisor/core/api/states/sensor.front_door_battery | jq .
```

`last_changed` on an entity tells you when it entered its current state — often
enough to date the failure without touching history at all.

## Reporting back

Lead with the finding, not the transcript. "Your Zigbee coordinator dropped at
02:14 — 23 devices went unavailable at the same moment, and the log shows the
serial port disconnecting" is useful. Pasting the whole report and asking the
user to interpret it is not. Include the raw section only when the user needs
to act on the detail.

If nothing is wrong, say that plainly too — a clean `ha-diagnose` is a real
answer to "is everything OK?".
