---
name: ha-config-safety
description: Safely change Home Assistant configuration under /config — snapshot before editing, validate against Home Assistant Core, roll back automatically when the check fails, and keep a git history of /config. Use this whenever you are about to create or modify anything under /config (configuration.yaml, automations.yaml, scripts.yaml, scenes.yaml, templates, packages, custom_components, dashboards), or when the user asks to add, fix, tidy or remove an automation, script, template, helper or integration setting. Also use it when Home Assistant refuses to start or reload after a config change, when the user wants to undo a change, or when they ask to back up, commit or roll back /config. Reach for it even when the user just says "change the porch light automation" without mentioning validation or backups — an unvalidated YAML edit is what takes their house offline.
---

# Editing Home Assistant config without breaking the house

A bad YAML edit under `/config` does not fail politely. Home Assistant refuses
to reload the affected integration, or refuses to restart at all, and the user
loses lights, heating and locks until someone fixes it — possibly someone who
can no longer reach this terminal. So the cost of an unchecked edit is much
higher than the cost of checking, and the tooling below exists to make checking
cheap.

Two commands do the work:

- `ha-validate` — asks Home Assistant Core itself whether the configuration is
  valid, and can restore a pre-edit snapshot when it isn't.
- `ha-git-backups` — keeps `/config` in a git repository so any change can be
  inspected and undone later.

## The safe edit loop

```bash
ha-validate                                    # 1. establish a clean baseline
ha-validate --backup /config/automations.yaml  # 2. snapshot BEFORE editing
# ... make the edit ...
ha-validate --safe-edit /config/automations.yaml  # 3. verify, auto-restore on failure
```

**Step 1 is not optional padding.** `check_config` validates the *whole
instance*, not the file you touched. If the configuration was already broken
before you arrived — a half-finished integration, a package referencing a
missing entity — then step 3 will fail for a reason that has nothing to do with
your edit, and it will roll your perfectly good work back. Run `ha-validate`
first so you know whether a later failure is yours. If the baseline is already
red, tell the user what is broken and agree on what to do before editing.

**Step 2 must happen before the edit, not after.** `--safe-edit` deliberately
does not create the backup itself: a snapshot taken after the edit preserves
the broken version, so "restoring" copies the same broken content back and
reports success. If you skip `--backup`, `--safe-edit` says so and validates
without any ability to roll back — usable, but you are then on your own to
repair the file by hand.

The backup lives at `<file>.bak` next to the original and is kept after a clean
run, so a stale `.bak` from a previous session may already exist. Taking a fresh
one before each edit is what makes it meaningful.

## Reading the result

`ha-validate` exits 0 and prints `✅ ... VALID`, or exits 1 and prints the
errors Core reported. On failure `--safe-edit` restores the file and still
exits 1, so a script wrapping it will notice.

Errors come back as free text from Home Assistant. Read them literally — they
usually name the file and the key. When the message is vague, the live error
log has more:

```bash
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  http://supervisor/core/api/error_log | tail -50
```

## Applying the change

A valid file is not a live file. Reload the specific integration rather than
restarting Home Assistant — a restart drops every connection in the house for
30+ seconds and is rarely necessary:

```bash
# automations.yaml, scripts.yaml, scenes.yaml, template entities, input helpers
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  http://supervisor/core/api/services/automation/reload
# also: script/reload, scene/reload, template/reload, input_boolean/reload, homeassistant/reload_all
```

Changes to `configuration.yaml` top-level keys, and anything under
`custom_components/`, do need a full restart
(`POST .../services/homeassistant/restart`). Say so and let the user decide
when — do not restart Home Assistant unprompted.

## Keeping history of /config

`ha-git-backups` turns `/config` into a git repository so changes are
recoverable beyond a single `.bak`:

```bash
ha-git-backups status                 # what has changed since the last commit
ha-git-backups commit "message"       # stage everything and commit
ha-git-backups rollback               # discard newest commit + uncommitted changes
ha-git-backups rollback --yes         # same, without the confirmation prompt
```

On first use it runs `git init` and writes a `.gitignore` that excludes
`secrets.yaml`, `known_devices.yaml`, `ip_bans.yaml`, `*.key`, `*.pem`, the
database, logs and `.storage/`. That exclusion list matters: `commit` runs
`git add -A`, so anything not ignored is written into history — and history
under `/config` rides along in every Home Assistant backup.

Committing before a substantial change gives the user a labelled point to
return to. It costs a second and it is the difference between "undo it" and
"rebuild it".

`rollback` is destructive: it runs `git reset --hard HEAD~1`, discarding both
the newest commit and any uncommitted work in `/config`. It prints exactly what
will be lost and requires the user to type `rollback` to confirm. Do not pass
`--yes` on the user's behalf — let them read the list and answer. If there is
no parent commit it refuses rather than erroring.

## Habits worth keeping

- Prefer editing the smallest file that expresses the change. Splitting a large
  `configuration.yaml` into `packages/` or `!include`d files makes future edits
  validate and roll back in isolation.
- When adding an automation, check the entity ids you reference actually exist
  (`curl .../api/states | jq -r '.[].entity_id' | grep <name>`). Core's config
  check accepts an automation pointing at an entity that does not exist; it
  simply never fires, which is a much harder bug to find later.
- Never write credentials into a YAML file directly. Put them in
  `secrets.yaml` and reference them with `!secret name` — that file is
  git-ignored for exactly this reason.
