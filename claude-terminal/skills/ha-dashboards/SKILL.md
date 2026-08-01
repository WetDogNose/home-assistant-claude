---
name: ha-dashboards
description: Generate and edit Lovelace dashboard YAML for Home Assistant with ha-dashboard, then register it so it appears in the sidebar. Use this whenever the user asks for a dashboard, a new view or tab, a page showing their lights/climate/sensors/cameras, a panel for a room, a card layout, or wants to reorganise how their Home Assistant UI is laid out. Also use it when they say things like "I want one screen with all my thermostats" or "can you make me a page for the garage" — that is a dashboard request even without the word. Prefer generating the YAML skeleton with ha-dashboard over hand-writing every card, then edit the result.
---

# Building Lovelace dashboards

`ha-dashboard` writes a working dashboard skeleton from live entity states, so
you start from real entity ids that exist in this instance rather than invented
ones. Treat its output as a first draft to edit, not a finished design.

## Generating

```bash
ha-dashboard <domain_or_area> [output_file]
```

```bash
ha-dashboard climate                                  # -> /config/dashboards/climate.yaml
ha-dashboard light /config/dashboards/all-lights.yaml
```

It fetches all states and selects entities whose id starts with
`<target>.` **or** whose `area_id` attribute equals `<target>`, then writes a
single view containing a 2-column grid of `type: entity` cards. If nothing
matches it stops with an error instead of writing the file — a grid card with
an empty `cards:` key is YAML Home Assistant refuses to load, so an "empty"
dashboard would be worse than none.

**Domain filtering is the reliable path.** Area filtering usually finds
nothing, because areas live in the entity/device registry and Home Assistant
does not generally expose `area_id` in the REST states payload. When the user
wants a room, resolve the area to entity ids first via the template endpoint,
then build the file from that list:

```bash
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"template": "{{ area_entities(\"Living Room\") | join(\"\n\") }}"}' \
  http://supervisor/core/api/template
```

`area_entities` accepts the area name or its id, and `area_id('<entity>')` goes
the other way when you need to check where something lives.

## Improving the draft

A grid of bare entity rows is functional and dull. Once the entity list is
right, spend the effort on card choice — that is what makes a dashboard worth
opening:

| Content | Better card than `entity` |
|---|---|
| Lights, switches, scenes | `tile` (with `features:` for brightness) or `light` |
| Thermostats | `thermostat` |
| A room's mixed devices | `area`, or `entities` grouped under one heading |
| Numeric sensors over time | `history-graph`, `statistic` |
| Cameras | `picture-entity`, `picture-glance` |
| Anything conditional | `conditional` wrapping the card |

Keep views under roughly a screenful. Multiple small views beat one long scroll
on the phone most people actually use.

## Registering the dashboard

A file under `/config/dashboards/` does nothing until Home Assistant is told
about it. Add it to `configuration.yaml`:

```yaml
lovelace:
  mode: storage          # keeps existing UI-editable dashboards working
  dashboards:
    climate-yaml:                    # url_path, must contain a hyphen
      mode: yaml
      title: Climate
      icon: mdi:thermometer
      show_in_sidebar: true
      filename: dashboards/climate.yaml
```

Two constraints catch people out: the key becomes the URL and **must contain a
hyphen**, and `filename` is relative to `/config`. Adding a dashboard requires a
Home Assistant restart; editing an already-registered YAML dashboard only needs
a browser refresh.

Because this edits `configuration.yaml`, follow the safe-edit flow from the
**ha-config-safety** skill — snapshot, validate, roll back on failure.

## A note on YAML mode

A YAML-mode dashboard cannot be edited from the Home Assistant UI. That is the
trade the user is making: version-controllable and scriptable, but the "Edit
dashboard" pencil is gone for that dashboard. Say so before converting an
existing storage-mode dashboard, and prefer adding a *new* YAML dashboard
alongside the user's existing ones rather than replacing what they already have.
