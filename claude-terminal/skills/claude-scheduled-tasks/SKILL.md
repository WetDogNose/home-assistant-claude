---
name: claude-scheduled-tasks
description: Schedule Claude to run a prompt on a repeating interval or at a wall-clock time in the background with claude-cron, so recurring checks and reports happen without anyone opening the terminal. Use this whenever the user wants something to happen every N minutes/hours/days, daily, at a particular time, on weekdays, on a cron schedule, regularly, in the background, or "keep an eye on" something — energy reports, battery sweeps, checking whether a device came back, nightly config backups. Also use it when they ask what is already scheduled, want to pause, resume, edit or delete a recurring job, want to run one right now, want to see a job's log or its last output, or when a scheduled job seems not to be running or "does nothing".
---

# Recurring background tasks

`claude-cron` runs prompts on a schedule and reports each result as a Home
Assistant notification. The daemon is started by the add-on at boot, so jobs
keep running whether or not anyone has the terminal open.

## Managing jobs

```bash
claude-cron list
claude-cron add "<schedule>" "<prompt>"
claude-cron remove <id>
claude-cron enable <id>       # resume a paused job
claude-cron disable <id>      # pause without deleting
claude-cron run <id>          # run it now, in the foreground, and show the output
claude-cron log [id]          # run history; all jobs, or one
claude-cron output <id>       # that job's most recent output in full
```

`disable` is almost always better than `remove` when a user says "stop that" —
it keeps the prompt and the id, so turning it back on is one command and no
retyping. `run` is how you verify a prompt without waiting for its schedule,
and its output goes to the terminal rather than to a notification.

## Schedules

Four forms are accepted:

| Form | Example | Meaning |
|---|---|---|
| bare minutes | `"30"` | every 30 minutes |
| `every N<unit>` | `"every 30m"`, `"every 6h"`, `"every 2d"` | interval, counted from the last run |
| `daily HH:MM` | `"daily 03:15"` | once a day at that local time |
| five-field cron | `"0 3 * * *"`, `"*/15 8-22 * * 1-5"` | minute hour day-of-month month day-of-week |

```bash
claude-cron add "every 6h"            "Check home energy usage and summarise it in two sentences"
claude-cron add "daily 07:00"         "List any device with a battery under 20% and name the room"
claude-cron add "*/15 8-22 * * 1-5"   "If the front door has been unlocked over an hour, say so in one line"
```

Cron fields support `*`, `*/n`, `a-b`, `a-b/n` and comma lists (`0,30`).
**Named months and weekdays are not supported** — `JAN`, `MON`, `MON-FRI` are
rejected when the job is added, not silently ignored at run time. Use numbers:
weekday `0`/`7` is Sunday, `1` is Monday.

Real cron day-of-month/day-of-week OR semantics are implemented: when *both*
those fields are restricted, the job fires when **either** matches, not when
both do. `"0 9 1 * 1"` is "the 1st of the month *and* every Monday", which
surprises people who expected an AND. If the user means one of them, leave the
other as `*`.

### Timing

Cron and `daily` schedules use the add-on's **local timezone**, so they line up
with the clock the user reads. `every N` counts from the job's last run, so it
**drifts** — a restart, a slow run, or a missed pass shifts the whole series
forward. Use `every N` for "roughly this often" and a cron or `daily` schedule
whenever the time itself matters.

Jobs are stored in `/data/claude-cron.json`, which persists across restarts and
is included in Home Assistant backups. The daemon re-reads the file every pass,
so adding, removing, enabling or disabling a job takes effect within a minute —
no restart needed.

A brand new job is due immediately, so an interval job usually runs within
about a minute of being added rather than after one full interval. That is
useful for checking the prompt works, and worth warning about if the prompt
does something the household will notice.

## Permissions — why a job "does nothing"

Scheduled runs now use **the same permission flags an interactive session
gets**, taken from the `dangerously_skip_permissions` and `claude_extra_args`
options.

With `dangerously_skip_permissions` off, a job can read and report perfectly
well but will **refuse to make changes** — there is nobody there to approve
them. This is by far the most common reason a scheduled job appears to run and
"do nothing": the run completes, the notification arrives, and the change never
happened.

So when a user wants a job that *acts* rather than reports, say the choice out
loud: either keep the job read-only, or enable
`dangerously_skip_permissions` knowingly and accept that every prompt — from
the terminal and the schedule alike — then runs unattended.

## Writing prompts that work unattended

Nobody is watching, so the prompt has to be self-sufficient in ways an
interactive request does not:

- **Say what output you want.** The whole stdout becomes a notification body.
  "Summarise in two sentences" produces something readable; an open-ended
  request produces a wall of text in the notification drawer.
- **Keep it read-only unless the user really wants autonomous changes.** A job
  that edits `/config` on a timer, with no one reviewing the diff, is how a
  house breaks at 3am. Read, report, and let a person act.
- **Expect it to run forever.** The user will forget it exists. Prompts whose
  usefulness expires ("check whether the update finished") should be disabled
  or removed once answered rather than left firing.

## Results

Each run's output is posted as a persistent notification titled
`Claude Cron Job [<id>]` via `ha-notify`, and kept for `claude-cron output`.

Scheduled runs **suppress the completion-notification hook** and report
themselves instead, so a job produces one notification, not two. If a user
complains about duplicates from a scheduled job, that is a bug, not the design
— see the **claude-terminal-notifications** skill for how the hooks work.

`claude-cron list` shows each job's schedule, enabled state and last run time
(`never` until it has run once), which is the fastest way to tell a broken job
from one that has simply not come round yet. `claude-cron log` shows what
actually happened on recent passes.

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
| "At 07:00 every weekday" | `claude-cron` with `"0 7 * * 1-5"` |
| "When the back door opens after dark" | HA automation + Automation API |
| Result should land in a notification | either — `claude-cron` does it for free |
| Result should feed back into an automation | Automation API (`response_variable`, or an async job event) |

Wall-clock scheduling no longer needs to go to the Home Assistant side —
`claude-cron` does it. What still belongs there is **event-driven** work, where
the trigger is something happening in the house rather than a time; see the
**claude-automation-api** skill.

## Before adding one

Scheduled jobs consume tokens on every run, forever, whether or not anyone reads
the result. Confirm the schedule with the user — hourly and daily are almost
always what people mean when they say "regularly", and "every 5 minutes" is
rarely worth 288 runs a day.
