---
name: claude-terminal-sessions
description: Run more than one Claude at a time in this add-on, and find out where the tokens are going. Use this whenever the user wants to "run two things at once", "start another session", do something "in parallel", work on something "while that's running", keep a long job going in the background, come back to a session after closing the browser tab, or asks how to switch between or clean up sessions. Also use it for cost and consumption questions — "how many tokens", "how much am I using", "what has this cost", "usage report", "token usage this month", "am I burning through my limit" — and when they want that usage on a Home Assistant dashboard.
---

# Parallel sessions and what they cost

The browser terminal is one tmux session with one Claude in it. That is the
right default, but it means a long task blocks everything else. `claude-session`
adds more of them; `claude-usage` says what they consumed.

## Running several at once

```bash
claude-session list                 # every session, which is attached, and its age
claude-session new                  # auto-named session
claude-session new energy-audit     # named session
claude-session switch energy-audit  # attach to one
claude-session kill energy-audit    # stop one
```

Each session is a separate tmux session running its own Claude, with its own
conversation and its own working state. They run concurrently — starting a long
analysis in one and going back to the main session is the whole point.

**Sessions outlive the browser tab.** Closing the tab, losing wifi, or
reloading the ingress page detaches; the session and everything running in it
carries on. `claude-session list` after reconnecting shows what is still there.
This is the correct answer to "can I close this and come back?" — yes, and no
special step is needed.

The session named `claude` is the one the browser attaches to on connect.
Killing it is refused unless you pass `--force`, because doing so drops whoever
is looking at the terminal into a dead session. There is almost never a reason
to; kill the named ones instead.

Inside tmux:

- `Ctrl+B` `s` — pick a session from a list
- `Ctrl+B` `d` — detach, leaving everything running

Those work whether or not the session was created by `claude-session`, and are
usually quicker than typing a command once more than one session exists.

### When to reach for a second session

Worth it when the first task is genuinely long and the second is unrelated — a
config audit while the user asks about a light, a long refactor while checking
history. Not worth it for two things that touch the same files: two Claudes
editing `/config` at once produce conflicts nobody asked for, and the tokens
are spent twice. Say so rather than spawning sessions on reflex.

## What it cost

```bash
claude-usage                # recent usage summary
claude-usage --days 30      # a longer window
claude-usage --json         # machine-readable, for scripting
claude-usage --publish      # push sensor.claude_terminal_tokens_today to Home Assistant
```

The numbers come out of Claude Code's own session transcripts on disk — this is
a report of what was already recorded, not a live meter or an API call to
Anthropic.

Two things about how it reports:

- **Cost appears only where Claude Code recorded one.** No price table is
  applied, and nothing is estimated from token counts. A run with no recorded
  cost shows tokens and no money, which is honest rather than broken. Do not
  fill the gap by multiplying tokens by a price you remember.
- **Cache reads are counted separately from fresh input.** That separation is
  the interesting part of a long session: cached input is the cheap half, so a
  large total input number with most of it in cache reads is a very different
  situation from the same number all fresh. Report the split, not just the sum.

`--publish` feeds `sensor.claude_terminal_tokens_today`, which can go on a
dashboard alongside the other add-on entities — see the
**claude-terminal-notifications** skill for how those entities behave (briefly:
Home Assistant does not persist REST-created states, so they reappear on a
heartbeat after a Core restart).

## Reporting usage back

Lead with the shape, not the table. "About 2.1M tokens over the last week,
three quarters of it cache reads from long sessions, no recorded cost on the
subscription" tells the user something. Pasting the whole breakdown does not.
Offer `--days 30` when they ask about a month and the default window is
shorter, and offer `--json` only if they are building something on top of it.
