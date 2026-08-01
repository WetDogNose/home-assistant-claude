---
name: ha-history
description: Answer questions about what Home Assistant entities did in the past using ha-memory and the history API — when a state changed, how often something happened, how long a device has been in its current state, whether a sensor has been reporting. Use this whenever the user asks "when did…", "how many times…", "has the … been…", "did the heating run last night", "when was the front door last unlocked", "how long has that been offline", or wants a timeline of anything in the house. Also use it when diagnosing an intermittent fault, because the moment a device started misbehaving is usually the fastest route to why. Prefer it over guessing from current state — current state cannot tell you when it changed or what came before.
---

# Querying Home Assistant history

Current state answers "what is it now". History answers "when did that start",
"how often", and "what was it before" — which is where most real questions
actually live.

## ha-memory

```bash
ha-memory <entity_id> [hours_back]     # hours_back defaults to 24
```

```bash
ha-memory lock.front_door 24
ha-memory climate.living_room 48
ha-memory binary_sensor.garage_motion 6
```

Prints one line per recorded state change, oldest first, capped at 30 lines:

```
[2026-07-31T22:14:03.120411+00:00] lock.front_door -> unlocked
[2026-07-31T22:14:41.882300+00:00] lock.front_door -> locked
```

`hours_back` must be a whole number of hours; anything else is rejected rather
than silently ignored. The first argument is passed through as
`filter_entity_id`, so a comma-separated list works for correlating entities:

```bash
ha-memory 'binary_sensor.hall_motion,light.hall' 12
```

**The 30-line cap is a display limit, not a data limit.** If you are counting
occurrences or looking at a busy sensor, you are almost certainly truncating —
query the API directly instead of reasoning from a truncated list.

## Going past the wrapper

`ha-memory` is a convenience layer over Core's history endpoint. Use the
endpoint when you need counting, aggregation, or a window that is not a whole
number of hours back from now:

```bash
# Every state change in a window, both ends explicit
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  "http://supervisor/core/api/history/period/2026-07-31T00:00:00Z?end_time=2026-08-01T00:00:00Z&filter_entity_id=lock.front_door" \
  | jq -r '.[][] | "\(.last_changed) \(.state)"'

# Count how many times it opened today
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  "http://supervisor/core/api/history/period/2026-08-01T00:00:00Z?filter_entity_id=binary_sensor.garage_door" \
  | jq '[.[][] | select(.state=="on")] | length'

# Long windows: drop attributes and keep only real changes
# minimal_response shrinks the payload; significant_changes_only skips
# attribute-only updates that would otherwise dominate a sensor's timeline.
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  "http://supervisor/core/api/history/period/2026-07-25T00:00:00Z?filter_entity_id=sensor.outside_temperature&minimal_response&significant_changes_only"
```

Timestamps are ISO-8601. Home Assistant interprets a naive timestamp in the
instance's local timezone and a `Z`-suffixed one as UTC — mixing the two is the
usual cause of an answer that is off by a few hours. `ha-memory` always sends
UTC.

For logbook-style events (who pressed what, which automation fired) rather than
state values, use `/api/logbook/<timestamp>` with the same `entity` filter.

## What history cannot tell you

The recorder only keeps what it was configured to keep. Two limits bite
regularly, and both look identical to "nothing happened":

- **`purge_keep_days`** (default 10) — ask for 30 days and you get 10. If a
  query returns nothing for an older window, check the recorder settings before
  concluding the event never occurred.
- **`recorder:` include/exclude filters** — many instances exclude noisy
  domains entirely. An entity absent from history may simply never have been
  recorded.

Say which of these you have ruled out when you report an empty result. "No
record of it in the last 10 days, which is as far back as this recorder keeps"
is an answer; "it never happened" may not be true.

## Turning history into an answer

- **"When did it break?"** — find the last state that looked healthy and the
  first that did not; report the boundary, then check what else changed at that
  moment (an update, a restart, another device).
- **"How often?"** — count transitions *into* the state, not lines. A sensor
  flapping `on/off/on` produces twice the lines for the same number of events.
- **"How long?"** — `last_changed` on the current state is the cheapest answer
  and needs no history call at all.

Report the times in the instance's local timezone (`.time_zone` from
`/api/config`); a household does not think in UTC.

