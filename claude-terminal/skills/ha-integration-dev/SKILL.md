---
name: ha-integration-dev
description: Write code that runs inside Home Assistant — custom integrations under /config/custom_components, PyScript automation handlers under /config/pyscript, and ESPHome device firmware — using ha-scaffold, esphome-setup and persist-install. Use this whenever the user wants to build a custom component or integration, add a sensor/switch/platform that Home Assistant doesn't have, write Python that reacts to state changes, work on an ESP32/ESP8266 or ESPHome YAML, or install a Python or Alpine package that must survive an add-on restart. Also use it for "can you write me an integration for my …" and "I want some Python that runs when X happens" — start from the generated scaffold rather than writing the boilerplate by hand, because Home Assistant's manifest, config-flow and entry-setup contracts are unforgiving about details.
---

# Developing against Home Assistant

Three different levels of "write some code for my house", with very different
costs. Pick the cheapest one that does the job:

| Need | Use | Restart required |
|---|---|---|
| React to a state change with some Python | PyScript | No — hot-reloads |
| A new device/service integration, config flow, entities | Custom integration | Yes |
| Firmware for an ESP32/ESP8266 sensor | ESPHome | Device reflash only |

Reaching for a full custom integration when a template sensor or a PyScript
handler would do is the most common overcorrection here — it is ten times the
code and requires restarting Home Assistant to test each change.

## Custom integrations

```bash
ha-scaffold <domain> [friendly_name] [description]
ha-scaffold solar_monitor "Solar Monitor" "Monitors solar inverter stats"
```

Creates `/config/custom_components/<domain>/` with `manifest.json`, `const.py`,
`__init__.py`, `config_flow.py`, `sensor.py`, `strings.json` and `README.md`.
The domain is lowercased and hyphens become underscores. It refuses to write
into an existing directory rather than overwriting work.

The scaffold is a *valid skeleton*, not a working integration: `sensor.py`
reports a hardcoded `"online"` and the config flow collects only a name.
Replace those with the real device logic. When editing it, keep these
invariants — they are what Home Assistant actually enforces:

- `manifest.json` `domain` must equal the directory name, and `version` is
  required for custom integrations.
- Anything the integration imports at runtime belongs in
  `manifest.json` `requirements`, not installed by hand — Home Assistant
  installs those into its own container, which is *not* this one.
- Network and device I/O must be async, or wrapped with
  `hass.async_add_executor_job`. Blocking the event loop shows up as the whole
  instance stuttering, and Home Assistant logs a warning naming your integration.
- For anything polling, prefer a `DataUpdateCoordinator` over per-entity
  `async_update` — one request per interval instead of one per entity.

Loading it needs a full Home Assistant restart. After the restart, check the
result rather than assuming:

```bash
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  http://supervisor/core/api/error_log | grep -i <domain>
```

An import error or a bad manifest means the integration is silently absent from
the "Add integration" list — the log is the only place it is reported.

## PyScript handlers

```bash
ha-scaffold pyscript <script_name> [description]
ha-scaffold pyscript smart_hvac "Automated HVAC control"
```

Writes `/config/pyscript/<name>.py` with a `@state_trigger` handler. **Edit the
trigger before doing anything else** — the template references
`binary_sensor.front_door_motion`, which almost certainly does not exist in this
instance, and a trigger on a non-existent entity simply never fires.

PyScript is not built in. It requires the `pyscript` custom integration
(installed via HACS or dropped into `custom_components/`) and `pyscript:` in
`configuration.yaml`. If neither is present, the file is inert — check before
writing one, and tell the user what they need to install.

Its programming model is deliberately unlike normal Python: `state.get()`,
`service.call()`, `task.sleep()`, and decorators (`@state_trigger`,
`@time_trigger`, `@service`) instead of Home Assistant's async APIs. Scripts
reload automatically on save, which makes it by far the fastest way to iterate.

## ESPHome

```bash
esphome-setup          # installs the ESPHome CLI, persisted across restarts
esphome version
```

The install goes through `persist-install`, which both installs the package and
records it in `/data/persistent-packages.json` so it is reinstalled after a
restart — the container filesystem is rebuilt every boot and anything installed
with a bare `pip3 install` disappears.

Device YAML conventionally lives in `/config/esphome/`. Typical loop:

```bash
esphome config    /config/esphome/sensor.yaml    # validate
esphome compile   /config/esphome/sensor.yaml    # build firmware
esphome run       /config/esphome/sensor.yaml    # build + upload (OTA)
esphome logs      /config/esphome/sensor.yaml    # serial/OTA logs
```

Compiling pulls a PlatformIO toolchain on first run — it is slow and needs
network. On a Raspberry Pi expect several minutes for a first build; say so
rather than letting the user think it has hung. If the official ESPHome add-on
is installed, that is usually the better place to build; this CLI is for when
you want scripted or Claude-driven builds in the same session as the rest of the
config work.

## Persisting other packages

```bash
persist-install apk vim htop        # Alpine packages
persist-install pip requests pandas # Python packages
persist-install list
persist-install remove pip pandas   # stops reinstalling; stays until restart
```

Use this instead of raw `apk add` / `pip3 install` for anything the user will
want again tomorrow. It is also the honest answer to "why did the thing you
installed disappear?".

Remember the split: packages installed here are available to **this terminal**.
Python packages an integration needs go in its `manifest.json` `requirements`,
because integrations run inside Home Assistant's container.
