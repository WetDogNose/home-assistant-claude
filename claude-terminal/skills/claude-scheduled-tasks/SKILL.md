---
name: claude-scheduled-tasks
description: Schedule Claude to run a prompt on a repeating interval in the background with claude-cron, so recurring checks and reports happen without anyone opening the terminal. Use this whenever the user wants something to happen every N minutes/hours, daily, regularly, on a schedule, in the background, or "keep an eye on" something — energy reports, battery sweeps, checking whether a device came back, nightly config backups. Also use it when they ask what is already scheduled, want to stop or change a recurring job, or when a scheduled job seems not to be running. Prefer this over sleep loops in the terminal, which die the moment the session or container restarts.
---

# Recurring background tasks

`claude-cron` runs prompts on an interval and reports each result as a Home
Assistant notification. The daemon is started by the add-on at boot, so jobs
keep running whether or not anyone has the terminal open.

## Managing jobs

```bash
claude-cron list
claude-cron add "<minutes>" "<prompt>"
claude-cron remove <job_id>
```

```bash
claude-cron add "60"   "Check home energy usage and summarise it in two sentences"
claude-cron add "1440" "List any device with a battery under 20% and name the room"
claude-cron list
claude-cron remove 2
```

The interval is **whole minutes**, not a cron expression — `1440` is daily.
There is no way to say "at 07:00"; if the user needs wall-clock timing, that
belongs in a Home Assistant automation with a `time` trigger calling the
Automation API instead (see the **claude-automation-api** skill). Say that
rather than approximating a daily 7am job with an interval that drifts from
whenever the add-on last restarted.

Jobs are stored in `/data/claude-cron.json`, which persists across restarts and
is included in Home Assistant backups. The daemon re-reads the file every pass,
so adding or removing a job takes effect within a minute — no restart needed.

A new job has `last_timestamp: 0`, which is far enough in the past to be due
immediately: expect the first run within about a minute of adding it, not after
one full interval. That is useful for verifying the prompt works, and worth
warning about if the prompt does something the household will notice.

## Writing prompts that work unattended

The daemon runs `claude -p "<prompt>"` with no flags and nobody watching, so
the prompt has to be self-sufficient in ways an interactive request does not:

- **Say what output you want.** The whole stdout becomes a notification body.
  "Summarise in two sentences" produces something readable; an open-ended
  request produces a wall of text in the notification drawer.
- **Keep it read-only unless the user really wants autonomous changes.** A job
  that edits `/config` on a timer, with no one reviewing the diff, is how a
  house breaks at 3am. Read, report, and let a person act.
- **Assume no interaction.** Anything that would prompt for permission stalls
  until the run ends. Prefer prompts that inspect state and report.
- **Expect it to run forever.** The user will forget it exists. Prompts whose
  usefulness expires ("check whether the update finished") should be removed
  once answered — `claude-cron remove` them rather than leaving them firing.

## Results

Each run's output is posted as a persistent notification titled
`Claude Cron Job [<id>]` via `ha-notify`. `claude-cron list` shows each job's
last run time (`never` until it has run once), which is the fastest way to tell
a broken job from one that has simply not come round yet.

The daemon logs each run to the add-on log:

```bash
# Is the scheduler even running?
pgrep -f "claude-cron daemon" >/dev/null && echo running || echo stopped
```

`ha-diagnose` reports the same thing in its daemon section. If it is stopped,
jobs simply never fire — restarting the add-on starts it again.

## Choosing between claude-cron and a Home Assistant automation

| Want | Use |
|---|---|
| "Every 30 minutes, report X" | `claude-cron` |
| "At 07:00 every weekday" | HA automation + Automation API |
| "When the back door opens after dark" | HA automation + Automation API |
| Result should land in a notification | either — `claude-cron` does it for free |
| Result should feed back into an automation | Automation API (`response_variable`) |

`claude-cron` is the low-ceremony option: one command, no `configuration.yaml`
edit, no restart. Event-driven or wall-clock-precise work belongs on the Home
Assistant side, where the triggers already exist.

## Before adding one

Scheduled jobs consume tokens on every run, forever, whether or not anyone reads
the result. Confirm the interval with the user — hourly and daily are almost
always what people mean when they say "regularly", and "every 5 minutes" is
rarely worth 288 runs a day.
