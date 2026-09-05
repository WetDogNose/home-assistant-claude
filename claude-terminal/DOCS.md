# Claude Terminal

Claude Code in a web terminal, as a Home Assistant app.

## About

This app runs Anthropic's [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI in a browser-based terminal (ttyd + tmux) with your Home Assistant configuration mounted. Open it from the sidebar, log in once, and ask Claude to write automations, debug YAML, or manage your setup.

## Installation

1. In Home Assistant, go to **Settings** → **Apps** → **App Store**
2. Click the **⋮** menu in the top right and choose **Repositories**
3. Add this URL and click **Add**:

   ```
   https://github.com/WetDogNose/home-assistant-claude
   ```

4. Find **Claude Terminal (WetDogNose)** in the store and click **Install**
5. Start the app, then click **OPEN WEB UI** to access the terminal
6. On first use, follow the OAuth prompts to log in to your Anthropic account

Images are pulled prebuilt from `ghcr.io/wetdognose`, so installing does not build anything on your Home Assistant machine.

Your credentials are stored under `/data` and persist across restarts and app updates, so you won't need to log in again.

> **This is a fork.** It uses the slug `claude_terminal_wdn`, distinct from
> upstream's `claude_terminal`, so it installs alongside the original instead
> of replacing it. Each has its own `/data`, so each needs its own Claude
> login and keeps its own session history. See
> [Upstream & attribution](#upstream--attribution).

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `auto_launch_claude` | `true` | Start Claude immediately when the terminal opens. Set to `false` to get a shell instead (run `claude` yourself). |
| `tmux_mouse` | `false` | Enable tmux mouse mode. Off by default (`false`) so native browser text selection, `Ctrl+C` / `Cmd+C` copying, and single-click URL opening work seamlessly. Set to `true` to enable tmux mouse pane selection. |
| `require_ingress_user` | `false` | Restrict the terminal to signed-in Home Assistant users. Off by default because not every installation forwards the identity — see Security notes before enabling. |
| `claude_auto_update` | `true` | Keep Claude Code current: installs the official native build into `/data` and updates it in the background on each startup. |
| `claude_version` | `""` | Pin Claude Code to `stable`, `latest`, or an exact `X.Y.Z`. Empty tracks the newest release. Use this if an upstream release will not run in this add-on — see below. |
| `dangerously_skip_permissions` | `false` | Launch Claude with `--dangerously-skip-permissions` (no confirmation prompts). **Read the security note below.** |
| `claude_extra_args` | `""` | Extra flags appended to every Claude launch, e.g. `--model claude-sonnet-5`. Values are split on spaces; quoted multi-word arguments are not supported. |
| `ha_smart_context` | `true` | Write a summary of your system to Claude's user memory (`~/.claude/CLAUDE.md`) so it knows your setup without being told. |
| `ha_context_refresh_hours` | `24` | How often to rewrite that summary. Your system changes and a summary written once at startup slowly stops matching it. `0` writes it at startup only. |
| `notify_on_completion` | `true` | Raise a Home Assistant notification when Claude finishes a long task or stops to ask you something — so you can start a job from your phone, put it down, and be told when it needs you. |
| `notify_after_seconds` | `60` | Only notify for responses that took at least this long. Every prompt fires the completion hook, so notifying for all of them fills the drawer within a day. |
| `notify_tts_target` | `""` | A `media_player` entity to speak notifications on as well as showing them. Empty keeps them silent. |
| `enable_ha_entities` | `true` | Publish the add-on's own state (busy, last run, sign-in needed) as Home Assistant entities, so dashboards and automations can see Claude rather than only call it. |
| `enable_ha_mcp` | `true` | Register the [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) MCP server so Claude can control Home Assistant directly. |
| `ha_mcp_version` | `"8.3.0"` | ha-mcp release to run. |
| `enable_automation_api` | `true` | Enable the HTTP Automation API daemon (port 8128) to trigger Claude non-interactively from HA automations. |
| `automation_api_port` | `8128` | Container port for the Automation API server. |
| `automation_api_key` | `""` | Optional static API key. If empty, a random 32-character token is auto-generated in `/data/automation_api_token`. |
| `git_user_name` | `""` | Name used to author git commits made from the terminal. Reapplied on every restart. |
| `git_user_email` | `""` | Email used to author git commits made from the terminal. Reapplied on every restart. |
| `persistent_apk_packages` | `[]` | APK packages reinstalled on every startup. |
| `persistent_pip_packages` | `[]` | Python packages reinstalled on every startup. |

## Usage

With default settings, Claude launches automatically inside a tmux session named `claude`. Navigating away in Home Assistant and coming back reattaches to the same session — your conversation survives.

Useful commands (in shell mode, or after exiting Claude):

```bash
claude          # start Claude Code
claude -c       # continue the most recent conversation
claude -r       # pick a past conversation to resume
ha-diagnose     # one-command Home Assistant & add-on system health check
ha-validate     # validate HA configuration via API (--backup <file> before an edit, --safe-edit <file> after)
ha-dashboard    # generate Lovelace YAML dashboard by domain or area (<domain_or_area>)
ha-mesh         # scan Zigbee, Z-Wave & Matter mesh network health and low batteries
ha-memory       # search HA historical event and state transitions (<entity_id> [hours])
ha-snapshot     # capture camera image for Claude vision inspection (<camera_entity>)
ha-scaffold     # generate boilerplate for custom integration (<domain>) or PyScript (pyscript <name>)
ha-git-backups  # git config time-machine backup and rollback (status|commit|rollback)
ha-assist       # query HA Assist voice conversation pipeline (<prompt>)
claude-bot      # remote messaging gateway for Telegram, Matrix, Discord (forward <prompt>)
claude-cron     # scheduled prompts (add|list|enable|disable|run|log|output), cron or "daily 07:00"
claude-session  # run several Claude sessions at once (new|list|switch|kill)
claude-usage    # token usage from Claude Code's own session transcripts
claude-hooks    # Home Assistant notifications for Claude events (status|test|install)
ha-entity       # publish the add-on's state as HA entities (set|sync|show|publish)
esphome-setup   # install & persist ESPHome CLI toolchain
ha-tts          # send text-to-speech announcement to HA media player
claude-doctor   # diagnose network, auth, and environment issues
claude-login-url   # save the OAuth login URL to /config (see Troubleshooting)
github-setup    # sign in to GitHub and enable git push (see GitHub below)
data-gc         # show what is using space under /data; 'data-gc clean' prunes it
ha-notify       # raise a Home Assistant notification (used by the add-on itself)
persist-install apk htop   # install packages that survive restarts
ha-context      # refresh the Home Assistant context file
```

### Built-in skills

Claude doesn't have to be told how these commands work — the add-on ships a set of **skills** describing its own tooling, installed into `~/.claude/skills/` at startup and loaded on demand when a request matches.

In practice that means you can ask for the outcome instead of the command: "why did the hall sensor stop reporting?", "make me a dashboard for the upstairs lights", "have Home Assistant ask Claude for an energy summary every morning". Claude picks up the relevant skill and uses the right tool with the right flags.

| Skill | Covers |
|---|---|
| `ha-config-safety` | Editing `/config` without breaking it — `ha-validate`, `ha-git-backups` |
| `ha-diagnostics` | `ha-diagnose`, `ha-mesh`, `claude-doctor` |
| `ha-history` | `ha-memory` and the history API |
| `ha-dashboards` | `ha-dashboard` and Lovelace YAML |
| `ha-integration-dev` | `ha-scaffold`, `esphome-setup`, `persist-install` |
| `ha-camera-vision` | `ha-snapshot` |
| `ha-announce` | `ha-tts`, `ha-notify`, `ha-assist` |
| `claude-automation-api` | The Automation API, the shipped blueprint, `claude-bot` |
| `claude-scheduled-tasks` | `claude-cron` |
| `claude-terminal-notifications` | `claude-hooks`, `ha-entity`, telling you what Claude is doing |
| `claude-terminal-sessions` | `claude-session`, `claude-usage` |

The shipped set is refreshed on every add-on start, so updates take effect and withdrawn skills are removed. Skills you write yourself in `~/.claude/skills/` are left untouched — including one that happens to share a name with a bundled skill, which wins and is kept.

### Terminal tips

- **Automatic Login Notifications**: When Claude Code displays an OAuth authorization link, a Home Assistant persistent notification is automatically sent to the notification drawer with a direct clickable link (`[👉 Authorize Claude Code]`). Claude Code wraps that URL across several terminal lines; the add-on stitches it back together, so the link in the notification is the whole URL and not the first line of it (fixed in 2.5.1-wdn.16 — before that the link opened and then failed to authorize).
- **Copying & URL Clicking**: With default settings (`tmux_mouse: false`), native browser selection works directly — select text with your mouse and copy with `Ctrl+C` / `Cmd+C` or right-click. Terminal URLs (`https://...`) can be clicked directly to open in a new tab.
- **Tmux Mouse Mode**: If `tmux_mouse: true` is enabled, `Shift+drag` bypasses tmux mouse mode to perform native browser selection, and `Shift+Click` opens URLs.
- **Pasting**: Use `Ctrl+Shift+V` (or `Cmd+V` / right-click, depending on browser).
- **Phones & tablets — the key bar**: touch devices get a row of keys along the
  bottom of the terminal, because software keyboards have none of them: `esc`,
  `tab`, `⇧tab`, `ctrl`, the four cursor keys, `/`, `|` and a clipboard paste
  button. `/` starts every Claude Code command and is buried behind a modifier
  layer on iOS; `|` is missing from some software keyboards entirely. The paste
  button only appears where the browser will allow reading the clipboard, which
  needs an `https` connection — over plain `http` on a LAN it is hidden rather
  than shown and failing on tap. They are what Claude Code is
  actually driven with — arrows move through its prompts and your input history,
  `esc` interrupts, `⇧tab` cycles the permission mode, and `ctrl` covers
  `Ctrl+C` and the tmux `Ctrl+B` prefix. Hold an arrow to repeat it. `ctrl` is
  sticky: tap it, then tap another key on the bar *or* type a letter on your own
  keyboard, and it applies to that one key. Tap `▾` to collapse the bar (the
  choice is remembered on that device) and `⌨` to bring it back. It appears only
  on touch devices — desktop browsers are unchanged.

### File access

The terminal starts in `/config` (your Home Assistant configuration). Also mounted:

- `/addon_configs` — configuration directories of your other add-ons
- `/share` — the shared folder

## Scheduled tasks

`claude-cron` runs prompts on a schedule with nobody watching:

```bash
claude-cron add "daily 07:00" "Summarise yesterday's energy use and notify me"
claude-cron add "0 */4 * * *" "Check every battery sensor and flag any under 20%"
claude-cron add "every 30m"   "Check whether the garage door has been left open"
claude-cron list
claude-cron run 2        # run job 2 now, in the foreground
claude-cron disable 2    # pause without deleting
claude-cron log 2        # recent runs
claude-cron output 2     # what it said last time
```

Schedules can be:

| Form | Meaning |
|---|---|
| `30` | Every 30 minutes (the original format, still accepted) |
| `every 30m` / `every 6h` / `every 2d` | Every N minutes, hours or days |
| `daily 03:15` | At that time, every day |
| `0 3 * * *` | Five-field cron: minute, hour, day, month, weekday |
| `*/15 8-22 * * 1-5` | Every 15 minutes, 8am–10pm, weekdays |

Cron fields support `*`, `*/n`, `a-b`, `a-b/n` and comma-separated lists. Named
months and weekdays (`JAN`, `MON`) are **not** supported and are rejected when
you add the job, rather than accepted and then never matching. Day-of-month and
day-of-week follow real cron's rule: when both are restricted, either one
matching fires the job.

Cron and `daily` schedules use the add-on's local timezone. `every N` schedules
count from the end of the last run, so they drift by however long the job takes
— which is what you want for "check every so often" and not for "report at 7am".

> **If a scheduled job appears to do nothing, this is almost always why.** Jobs
> run with the same permission flags an interactive session gets. With
> `dangerously_skip_permissions` off (the default), a job can read and report
> but will refuse any change it would normally ask you to approve — and on a
> schedule there is nobody to ask. `claude-cron add` prints a reminder when you
> add a job in that state.

## Being told what Claude is doing

The terminal is most useful from a phone, and a phone is the device you put
down. Previously a task you started was invisible the moment you closed the tab:
you had to reopen the add-on to find out whether Claude had finished, failed, or
been sitting waiting for permission the whole time.

The add-on now installs **Claude Code hooks** that report those moments to Home
Assistant. With `notify_on_completion` on (the default) you get a notification:

- **when a response finishes** — including what Claude actually said, pulled
  from the session transcript. Only for responses that took at least
  `notify_after_seconds` (default 60), because every prompt fires this and
  notifying for all of them would fill the drawer within a day.
- **when Claude is waiting for you** — a permission prompt, or a question.

Set `notify_tts_target` to a `media_player` entity and the same notifications
are spoken.

```bash
claude-hooks status    # what is installed and how it is configured
claude-hooks test      # send a test notification down the same path
```

The hooks live in `~/.claude/settings.json` and are rewritten on every start, so
changing the options above takes effect on the next restart and a hook a
previous release installed is withdrawn. **Hooks you have written yourself in
that file are never touched** — only entries the add-on put there are managed.
If the file is not valid JSON the add-on leaves it entirely alone rather than
replacing what you were in the middle of writing.

Automation API and scheduled runs deliberately do *not* fire these hooks; they
report their own results, and without the suppression every automated prompt
would notify you twice.

## Claude Terminal as Home Assistant entities

With `enable_ha_entities` on (the default), the add-on publishes its own state
so you can put it on a dashboard or trigger automations from it:

| Entity | Tells you |
|---|---|
| `binary_sensor.claude_terminal_busy` | Claude is working right now |
| `binary_sensor.claude_terminal_login_required` | Claude Code needs you to sign in again |
| `sensor.claude_terminal_status` | `idle`, `running` or `waiting` |
| `sensor.claude_terminal_last_run` | When the last prompt finished |
| `sensor.claude_terminal_last_result` | `ok` or `error`, with the error as an attribute |
| `sensor.claude_terminal_version` | The running add-on version |
| `sensor.claude_terminal_tokens_today` | Published by `claude-usage --publish` |

> **These entities disappear when Home Assistant restarts.** That is not a bug
> in the add-on: states created through Home Assistant's REST API are runtime
> state and Core does not persist them. The add-on republishes them every five
> minutes, so they come back on their own within a few minutes of a restart —
> but an automation that triggers on one should tolerate it being briefly
> missing.

You can publish your own values too:

```bash
ha-entity set busy=true status=running     # update and publish
ha-entity show                             # what the add-on currently thinks
ha-entity publish sensor.my_thing "42" '{"friendly_name": "My thing"}'
```

## Running more than one thing at once

`ttyd` attaches the browser to a single tmux session called `claude`, which is
what makes reconnecting land you back where you were. It also means a long
refactor blocks the quick question you wanted to ask while it ran.

```bash
claude-session new refactor    # start another Claude and switch to it
claude-session list            # what is running
claude-session switch claude   # back to the one the browser attaches to
claude-session kill refactor
```

Sessions survive closing the browser tab. Reopening the add-on always returns
you to `claude`; use `switch` to get back to the others. Killing `claude` itself
would disconnect you and is refused without `--force`. Inside tmux, `Ctrl+B s`
picks a session from a list and `Ctrl+B d` detaches.

## What it is costing

```bash
claude-usage              # the last 7 days
claude-usage --days 30
claude-usage --json
claude-usage --publish    # also publish sensor.claude_terminal_tokens_today
```

Figures come from the usage Claude Code records in its own session transcripts.
Cache reads are reported **separately** from fresh input, because they are the
cheap half of a long session and folding them together makes a well-cached day
look far more expensive than it was.

A cost column is shown only where Claude Code recorded a cost. The add-on does
not apply a price table of its own — a hardcoded rate would go stale silently
and be believed anyway.

## Home Assistant MCP Integration

The bundled [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) server connects Claude to Home Assistant through the Supervisor API — no token setup needed. Claude can query states, control devices, and manage automations, scripts, and dashboards in natural language.

ha-mcp requires Python 3.13, which Alpine doesn't ship — the add-on provisions a managed Python build via [uv](https://github.com/astral-sh/uv) into `/data` on first use (a one-time ~150–250 MB download that persists across restarts and is included in HA backups). The environment is pre-warmed in the background at startup so the first MCP connection is fast.

Disable it with `enable_ha_mcp: false` if you don't want Claude to have this access.

## Home Assistant Automations (Automation API)

The add-on includes a built-in Automation API daemon that lets Home Assistant automations, scripts, and blueprints execute Claude prompts non-interactively (`claude -p "..."`).

### Security Controls

- **Token Authentication**: All requests require an `X-API-Key` or `Authorization: Bearer` header. On first boot, if `automation_api_key` is empty, a random 32-character secret token is generated in `/data/automation_api_token`.
- **Container Network Isolation**: Port `8128` is not exposed to the physical LAN (`ports:` is omitted in `config.yaml`). It is accessible only internally over the Home Assistant `hassio` Docker bridge network.
- **Client IP Whitelisting**: Only calls originating from internal container subnets (`172.16-31.x.x`, `10.x.x.x`, `127.0.0.1`) are accepted.
- **Process Mutex & Rate Limiting**: Prompts are executed sequentially (max 1 active process) with a 10 requests/minute rate limit per IP. Reading job status has its own, larger budget (120/minute) so polling a long job cannot exhaust your ability to start one. The limit is applied *before* authentication, so a wrong token cannot be retried indefinitely.
- **Command Injection Safety**: Prompts are passed directly via array arguments to `subprocess.run(..., shell=False)`.

### Long prompts: use `async`

Home Assistant's `rest_command` gives up after **10 seconds** unless you raise
its `timeout`, and most prompts worth automating take longer than that. A plain
synchronous call therefore fails for most real automations while appearing to
work when you test it with something trivial.

Post `"async": true` instead. The API answers `202` immediately:

```json
{"job_id": "a1b2c3d4e5f6", "status": "queued", "poll_url": "/api/jobs/a1b2c3d4e5f6",
 "event": "claude_terminal_job_finished"}
```

and when the prompt finishes it fires the Home Assistant event
**`claude_terminal_job_finished`**, with:

| Field | Meaning |
|---|---|
| `job_id` | The id returned by the 202 |
| `status` | `completed` or `failed` |
| `success` | Boolean form of the same |
| `session` | The named session, if you used one |
| `duration_seconds` | How long the prompt took |
| `response` | Claude's answer, truncated to 1000 characters |
| `truncated` | `true` when it was cut |
| `error` | Failure text, truncated to 500 characters |

Trigger a second automation on that event and you have "ask Claude something
slow, then act on the answer" without holding a connection open. The shipped
**Act on a finished Claude job** blueprint does exactly this.

`GET /api/jobs/<id>` (same `X-API-Key`) returns the full, untruncated result,
and `GET /api/jobs` lists recent jobs. Jobs are kept **in memory**, capped at 50,
and are lost when the add-on restarts — the fired event is the durable record,
which is why acting on the event is preferred over polling.

### Named sessions

Every API call is otherwise a cold start with no memory of the last one, so an
automation can ask Claude a question but never hold a conversation. Add a
`session` key — up to 64 letters, digits, `-` or `_` — and calls sharing that
name continue the same Claude session:

```json
{"prompt": "And what about yesterday?", "session": "energy", "async": true}
```

The first call creates the session; later ones resume it. If the underlying
Claude session has been pruned (they do not live forever, and a `/data` restored
from an older backup will not have it), the next call transparently starts a
fresh one rather than failing.

### Getting Your API Token

Inside the terminal or via Home Assistant's File Editor / Samba, inspect your token:
```bash
cat /data/automation_api_token
```

Store this token in your Home Assistant `secrets.yaml`:
```yaml
claude_api_token: "YOUR_32_CHAR_TOKEN"
```

### Home Assistant Setup Example

1. **Add `rest_command` to `configuration.yaml`**:
   ```yaml
   rest_command:
     claude_prompt:
       url: "http://claude_terminal_wdn:8128/api/prompt"
       method: POST
       headers:
         Content-Type: "application/json"
         X-API-Key: "!secret claude_api_token"
       payload: '{"prompt": "{{ prompt }}"}'
       timeout: 120
   ```

2. **Automation Example (Daily Home Audit)**:
   ```yaml
   alias: "Claude Daily Security & Energy Summary"
   trigger:
     - trigger: time
       at: "21:30:00"
   action:
     - action: rest_command.claude_prompt
       data:
         prompt: "Check all door sensors and energy usage, then send a summary notification"
       response_variable: claude_result
     - action: persistent_notification.create
       data:
         title: "Claude Home Audit"
         message: "{{ claude_result.content.response }}"
   ```

### Using the shipped blueprint

The add-on installs a **Claude Terminal Task Trigger** blueprint into
`/config/blueprints/automation/` (when that directory exists), so it shows up
under **Settings → Automations & scenes → Blueprints**.

Blueprints are installed **once**, not re-copied on every start. Delete one and
it stays deleted; edit one and your edits survive restarts. A later add-on
release updates a file only if you haven't changed it. If you removed one and
want it back, delete its baseline copy from `/data/blueprint-baselines/` and
restart the add-on.

> **Choosing a trigger matters.** An automation built from this blueprint can
> make Claude act on Home Assistant, and those actions produce state changes,
> logbook entries and log records. A trigger that fires on Home Assistant's own
> output — `system_log_event`, the error log, logbook entries, a bare
> `state_changed` — can therefore re-fire on the previous run's consequences and
> keep going. Trigger on the specific thing you care about instead.
>
> The blueprint ships with `mode: single` and `max_exceeded: silent` so
> overlapping runs are dropped without logging a warning (the warning would
> itself be an event such a trigger could fire on), and the Automation API caps
> callers at 10 requests/minute with a single-execution mutex. Those bound the
> damage; they don't replace picking a sane trigger.

It calls a REST command, and Home Assistant only lets you declare those in
`configuration.yaml`. Add this once and restart Home Assistant before using the
blueprint:

```yaml
rest_command:
  claude_terminal_query:
    url: "{{ url }}"
    method: POST
    headers:
      X-API-Key: "{{ token }}"
    content_type: "application/json"
    payload: >-
      {"prompt": {{ prompt | to_json }}
      {%- if session is defined and session %}, "session": {{ session | to_json }}{% endif %}
      {%- if run_async is defined and run_async %}, "async": true{% endif %}}
    timeout: 150
```

The `session` and `run_async` parts are optional and are simply omitted when a
blueprint does not pass them, so this one definition serves all four shipped
blueprints. If you already have the shorter version from an earlier release it
still works — but the scheduled-report and voice blueprints need this one.

The blueprint's default URL is `http://claude_terminal_wdn:8128/api/prompt`.

### The shipped blueprints

Four blueprints are installed into `/config/blueprints/automation/`:

| Blueprint | What it does |
|---|---|
| **Claude Terminal Task Trigger** | The original: any trigger you choose fires a prompt. |
| **Ask Claude with your voice** | An Assist sentence trigger ("ask claude …") sends the question and speaks the answer back through your voice assistant. This is the one place a *synchronous* call is right, because the assistant is already waiting — keep these questions short. |
| **Scheduled Claude report** | Runs a prompt at a time you pick, asynchronously, and does not wait. Pair it with the next one. |
| **Act on a finished Claude job** | Triggers on `claude_terminal_job_finished` and delivers the result as a notification, a `notify.*` service call and/or speech. |

Each is installed **once** and then left alone — see the note above about edits
and deletions, which applies to all of them.
Home Assistant Core runs in its own container, so the add-on has to be addressed
by slug — `127.0.0.1` would point at Home Assistant itself. Change the port only
if you changed the `automation_api_port` option.

## GitHub

The [GitHub CLI](https://cli.github.com/) (`gh`) is included, so Claude can read
and manage your repositories — issues, pull requests, releases, Actions runs —
and push commits, all from the terminal.

### Setup

Run `github-setup` once and follow the prompts:

```bash
github-setup
```

You'll get a short `github.com/login/device` URL and an 8-character code. Open
the URL on any device, enter the code, and authorize. Because both are short,
this avoids the clipboard-truncation problem that affects Claude's own login
(see Troubleshooting).

The helper then runs `gh auth setup-git`, which is what actually makes
`git push` work — authenticating alone is not enough, and skipping this step is
the usual reason a push later fails asking for a password.

Set `git_user_name` and `git_user_email` in the add-on configuration so commits
have an author; git refuses to commit without one. Both are reapplied on every
restart.

Your credentials are written to `/data/.config/gh/hosts.yml` and persist across
restarts and add-on updates, so this is a one-time setup. Sign out with
`gh auth logout`.

### Security

Read this before signing in — it grants real access.

- **Your token is stored in plaintext and is included in Home Assistant
  backups.** Alpine has no keyring, so `hosts.yml` holds the token as text, and
  `/data` is part of every backup. Treat your backups as secrets.
- **Choose scopes narrowly.** The `gh auth login` defaults are usually right.
  Avoid the `workflow` scope unless you need it — it permits rewriting CI
  workflows, which is arbitrary code execution in GitHub Actions. For the
  tightest control, create a fine-grained token limited to specific
  repositories and use `gh auth login --with-token`.
- **GitHub content is untrusted input.** Issue text, pull request descriptions
  and READMEs are written by other people. Once Claude can read them and also
  push, a prompt injection hidden in an issue has both a source and a channel.
  Keeping `dangerously_skip_permissions` off means pushes still need your
  confirmation, which is the main thing standing between the two.
- **Revoking is easy** — `gh auth logout`, or revoke the token in your GitHub
  settings. Do that if you hand a backup to anyone.

## Security notes

**This add-on gives Claude a lot of power by design**: it runs as root in its container, has read/write access to `/config`, `/addon_configs`, and `/share`, and (with MCP enabled) can control devices and modify automations.

**Any signed-in Home Assistant user can open this terminal** unless you set `require_ingress_user`. `panel_admin` only hides the sidebar entry; it is not access control. The option defaults to off because turning it on breaks the terminal outright on installations whose ingress sessions carry no user identity, and a hardening option that bricks the add-on for some users cannot be the default. The add-on raises a one-time notification explaining this. Whether your installation forwards the identity header cannot be detected from inside the container — the only way to find out is to turn the option on, restart, and see whether the terminal still connects.

**`dangerously_skip_permissions` removes the last human checkpoint.** With it enabled, a misunderstanding — or a prompt injection in any file or web page Claude reads — can modify your HA configuration or actuate devices without asking you first. Leave it off unless you understand and accept that trade-off. A warning banner is printed in the add-on log whenever it is active.

## Troubleshooting

- **The sign-in link does not authorize / "Invalid request format"**: on 2.5.1-wdn.15 and earlier both the sign-in notification and `claude-login-url` cut the URL off at the width of the terminal, dropping the `state` and `code_challenge` parameters. Update to 2.5.1-wdn.16 or later, then start the login again — the URL Claude Code prints is only valid for one attempt, so an already-issued one cannot be repaired by hand.
- **Can't copy the OAuth login URL**: run `claude-login-url` — as well as writing the URL to `/config`, it now pushes it to your Home Assistant **notifications**, where you can select and copy it with the browser's own clipboard. Full detail: the browser terminal's clipboard path truncates very long payloads, and the login URL is one — a cut-off `state` parameter causes exactly that authorization error. Reliable path: while the login prompt is showing, open a second tmux window (`Ctrl+B` then `C`), run `claude-login-url`, and open `/config/claude-login-url.txt` with the File Editor add-on (or over Samba) — copy the URL from there. Switch back with `Ctrl+B` then `L` to paste the resulting code. Delete the file when done. Don't click the link in the terminal directly: link detection truncates URLs that wrap across lines.
- **"Press Enter to Reconnect", or the panel loads but never connects**: you have `require_ingress_user: true` and your installation does not attach the user identity to the ingress WebSocket. Set it back to `false` and restart. This is why the option defaults to off.
- **No key bar on a phone or tablet**: the bar is shown when the browser reports a touch-style pointer, so a device reporting a mouse (some Android tablets in desktop mode, or a browser with desktop-site forced) will not get it — turn desktop-site off and reload. If it is missing everywhere, including on a phone, the add-on log will carry `serving ttyd's stock client (no touch key bar)`; that means the image is built without it, and reinstalling or updating the add-on restores it.

- **I never get completion notifications**: run `claude-hooks status`. The most common cause is `notify_after_seconds` (default 60) — short answers deliberately do not notify, so test with something that takes a minute, or lower the value. `claude-hooks test` sends one immediately down the same path. If the hooks are missing entirely, check the add-on log for `Could not install Claude Code hooks`, which means `~/.claude/settings.json` could not be written or is not valid JSON — the add-on refuses to overwrite a settings file it cannot parse.
- **Two notifications for every scheduled job**: an older `~/.claude/settings.json` with hand-copied hooks in it. The add-on only manages entries whose command begins with `claude-hooks handle`; remove any duplicates you added yourself.
- **The `claude_terminal_*` entities are missing**: they vanish whenever Home Assistant Core restarts, because states created through the REST API are not persisted by Core. The add-on republishes them every five minutes — wait, or restart the add-on to publish immediately. If they never appear, check `enable_ha_entities` is on and run `ha-entity sync` in the terminal to see the error.
- **A scheduled job runs but changes nothing**: see the warning under Scheduled tasks — without `dangerously_skip_permissions` a job cannot approve its own actions. `claude-cron output <id>` shows what it actually said.
- **An automation gets no response from the API**: if it calls the API synchronously, it is almost certainly Home Assistant's `rest_command` 10-second default timeout rather than anything in the add-on. Use `"async": true` and trigger on the `claude_terminal_job_finished` event instead.
- **Terminal opens blank or closes instantly**: this means Claude Code could not start. The add-on now detects that at launch and drops you to a shell with an explanation instead of a blank screen, so run `claude-doctor` there — it reports each installed copy and whether it actually runs. The usual cause is an update pulling a build incompatible with this image; `rm -f ~/.local/bin/claude` and restart to fall back to the bundled copy, then set `claude_version` to a known-good `X.Y.Z` so the next update does not reintroduce it.
- **Claude exits immediately or behaves oddly**: restart the add-on so the background auto-updater can fetch the latest Claude Code; check the add-on log for update messages.
- **Diagnostics**: run `claude-doctor` in the terminal for connectivity, memory, and environment checks.
- **Authentication problems**: run `claude /logout` inside Claude, then log in again.
- **Old backups too large?** Versions before 2.3.0 accumulated an npm cache in the add-on's data directory (up to several GB). 2.3.0 removes it automatically on first boot — take a fresh backup after upgrading.

## Upstream & attribution

The Claude Terminal add-on is the work of
**[Tom Cassady (@heytcass)](https://github.com/heytcass)** and contributors, in
[heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons).
All credit for the original add-on belongs there.

This fork changes only how the add-on is built and distributed: images are
built by this repository's CI and published to `ghcr.io/wetdognose`, so what
Home Assistant runs is built from source you can inspect. Both projects are
MIT licensed; original work © Tom Cassady and contributors.

Report problems with **this fork** at
<https://github.com/WetDogNose/home-assistant-claude/issues>, not upstream —
the upstream maintainer did not build these images and cannot reproduce
changes made here.

## Credits

This add-on was created with the assistance of Claude Code itself! The development process, debugging, and documentation were all completed using Claude's AI capabilities - a perfect demonstration of what this add-on can help you accomplish.
