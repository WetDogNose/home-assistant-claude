---
name: claude-terminal-notifications
description: Get told what Claude is doing — push a Home Assistant notification when a long response finishes or when Claude is stuck waiting for permission, speak it aloud, and publish Claude's own state as Home Assistant entities you can put on a dashboard. Use this whenever the user says "tell me when it's done", "notify me", "let me know when you finish", "ping me when that's finished", asks "did that finish?", "is Claude busy?", wants Claude's status, activity, last run or token use "on my dashboard", wants to "add a sensor for" the add-on, or wants an automation to react to Claude being busy or needing a login. Also use it for troubleshooting — "why didn't I get a notification", "I never get notifications", "the notification came too late", or entities that show as unavailable or disappeared after a Home Assistant restart.
---

# Telling the house what Claude is doing

Two independent mechanisms, and it is worth knowing which one the user is
actually asking about:

- **Hooks** fire on Claude Code events and push a *notification* — an event in
  time, "this finished", "this is stuck".
- **Entities** publish *state* — something a dashboard card or an automation
  can read at any moment, "Claude is busy right now".

`ha-notify` and `ha-tts` are the manual, one-off versions of the first.

## Hooks — notify me when it's done

```bash
claude-hooks status     # what is wired, and what the options say
claude-hooks test       # fire a test notification through the same path
claude-hooks install    # (re)write the hook config
claude-hooks remove     # unwire them
```

Hooks are installed automatically at add-on boot, so `install` is only needed
after editing the config by hand. `status` first, always — it answers "why
didn't I get a notification" faster than any amount of reasoning.

Four events are wired:

| Event | What it does |
|---|---|
| `UserPromptSubmit` | Marks Claude busy |
| `Stop` | Notifies that a response finished — **only if it took at least `notify_after_seconds`** |
| `Notification` | Notifies that Claude is waiting for permission or input |
| `SessionEnd` | Clears busy |

The `Stop` notification includes the last thing Claude said, read back out of
the session transcript, so the notification is usually enough on its own
without opening the terminal.

**The single most common cause of "I never get notifications"** is the
threshold: `notify_after_seconds` defaults to 60, so anything that finishes
quickly is deliberately silent. That is the feature working — a notification
for every two-second answer is noise. Check `notify_on_completion` is on and
lower the threshold if the user genuinely wants short runs announced.

Setting `CLAUDE_TERMINAL_NO_HOOK_NOTIFY=1` in the environment suppresses hook
notifications for that process. Automation-API calls and scheduled jobs set it
themselves, because they report their own results — without it every scheduled
job would announce itself twice.

Options that control this: `notify_on_completion`, `notify_after_seconds`,
`notify_tts_target`.

## Entities — Claude's state on a dashboard

```bash
ha-entity show                       # what is currently published
ha-entity sync                       # republish everything now
ha-entity set busy=on status="Working on the energy report"
ha-entity publish sensor.claude_terminal_note "hello" '{"icon":"mdi:robot"}'
```

Published when `enable_ha_entities` is on:

| Entity | Holds |
|---|---|
| `binary_sensor.claude_terminal_busy` | Whether a prompt is running right now |
| `binary_sensor.claude_terminal_login_required` | Claude needs signing in again |
| `sensor.claude_terminal_status` | Short human-readable activity |
| `sensor.claude_terminal_last_run` | When the last prompt ran |
| `sensor.claude_terminal_last_result` | How it ended |
| `sensor.claude_terminal_version` | Add-on version |
| `sensor.claude_terminal_tokens_today` | Published by `claude-usage --publish` |

**Home Assistant does not persist states created through its REST API.** These
entities are not backed by an integration or a config entry — they exist only
in Core's in-memory state machine, so a Core restart wipes them and they read
as unavailable or vanish from the entity list entirely until something
republishes them. That is Home Assistant behaving as designed, not a bug in the
add-on, and it is worth saying plainly rather than letting the user hunt for a
broken integration.

The add-on runs a heartbeat that republishes them every few minutes, which is
why they come back on their own after a restart. If a user reports them missing
right after restarting Core, the answer is usually "wait a few minutes, or run
`ha-entity sync`".

Because they are plain states, template sensors, automations and dashboard
cards can use them like anything else — but do not build anything that assumes
they survive a restart with history intact. For anything that must be durable,
have Claude write to a `input_text`/`input_boolean` helper instead.

## One-off notifications

```bash
ha-notify "Backup done" "Config backed up, 4 files changed"
ha-notify "Backup done" "Config backed up" backup_status   # reuses/replaces that id
ha-tts "The garage door has been open for an hour"
ha-tts "Dinner timer finished" media_player.kitchen_speaker
```

`ha-notify` posts a persistent notification; passing an id lets a repeated
message replace the previous one instead of stacking up. `ha-tts` speaks
through `notify_tts_target` unless a media player is named.

Use these when the user asks for a notification *about a specific thing*, and
the hooks when they want to be told *when Claude itself finishes*. Reaching for
`ha-notify` at the end of a long task is fine and often better — it can say
what actually happened.

## Sizing it right

Notifications are cheap to add and expensive to ignore. One that fires on every
run trains the user to swipe them away, at which point the one that mattered is
gone too. Prefer the threshold, prefer a single summary at the end of a job,
and prefer an entity over a notification whenever the user only wants to be
able to *check*, not to be interrupted.
