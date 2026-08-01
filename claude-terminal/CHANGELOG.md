# Changelog

## 2.5.1-wdn.14

### 🧠 Claude now knows how to use the add-on's own tools

Everything added since wdn.5 — `ha-validate`, `ha-mesh`, `ha-memory`,
`ha-dashboard`, `ha-scaffold`, `ha-snapshot`, `ha-tts`, `ha-assist`,
`ha-git-backups`, `claude-cron`, `claude-bot`, the Automation API — was
reachable only if the user already knew the command existed and typed it. Claude
sitting in the same terminal had no idea any of it was there, and would answer
"when did the back door last unlock?" by hand-rolling a `curl` against the
history API instead of running `ha-memory`.

Nine Claude Code **skills** now ship with the add-on, installed into
`~/.claude/skills/` at startup and loaded on demand when a request matches:

| Skill | Covers |
|---|---|
| `ha-config-safety` | Safe `/config` edits: `ha-validate`, `ha-git-backups` |
| `ha-diagnostics` | `ha-diagnose`, `ha-mesh`, `claude-doctor` |
| `ha-history` | `ha-memory` and the history API |
| `ha-dashboards` | `ha-dashboard`, Lovelace YAML |
| `ha-integration-dev` | `ha-scaffold`, `esphome-setup`, `persist-install` |
| `ha-camera-vision` | `ha-snapshot` |
| `ha-announce` | `ha-tts`, `ha-notify`, `ha-assist` |
| `claude-automation-api` | Automation API, the shipped blueprint, `claude-bot` |
| `claude-scheduled-tasks` | `claude-cron` |

The practical effect is that you can ask for the outcome rather than the
command: *"why did the hall sensor stop reporting?"*, *"make me a dashboard for
the upstairs lights"*, *"have Home Assistant ask Claude for an energy summary
each morning"*.

They also carry the operational knowledge that is not in any `--help` text, and
which wdn.13 spent a whole release discovering: that `ha-validate --backup` has
to run *before* the edit or the rollback restores the broken file; that
`check_config` validates the whole instance, so an unrelated pre-existing error
will roll back a good edit unless you check the baseline first; that
`/api/query` is not a route; that from Home Assistant Core's container the
Automation API is `claude_terminal_wdn:8128`, not `127.0.0.1`; that
`ha-git-backups rollback` destroys uncommitted work; and that `area_id` is
usually absent from the REST states payload, so `ha-dashboard <area>` finds
nothing and the area has to be resolved through the template endpoint.

**Skills are shipped state, not user state.** `/data` persists, so a skill
copied there once would outlive the release that shipped it — a withdrawn skill
would go on describing commands that no longer exist. The bundled set is
therefore cleared and re-copied on every start. Only directories the add-on
installed are cleared: a skill you wrote yourself under `~/.claude/skills/` is
left alone, including one sharing a name with a bundled skill, which wins and is
kept with a warning in the log.

### 🛡️ The bundled blueprint stops rewriting the user's config

`sync_blueprints` copied `claude_automation_query.yaml` into
`/config/blueprints/automation/` on **every add-on start**. Three consequences,
all bad and none obvious:

- **You could not decline it.** Delete the blueprint and it reappeared at the
  next restart.
- **You could not harden it.** Any local edit was silently reverted on the next
  restart.
- **It showed up as untracked churn** in any git repository kept over `/config`
  — which this add-on actively encourages via `ha-git-backups`.

It is now installed **once**, with a baseline copy recorded in
`/data/.blueprint-baseline.yaml`. A later release updates the file only when it
still matches that baseline, an edited file is left alone, and a deleted one is
not recreated (remove the baseline to opt back in). Upgrading from an earlier
version overwrites once and records the baseline, which cannot lose an edit —
the old behaviour guaranteed the file was the shipped content at every boot.

The path is deliberately **not** moved into a vendor subdirectory: automations
reference a blueprint by path, so relocating it would break every automation
already built from it.

### 🔁 Feedback-loop guards on the blueprint

An automation built from this blueprint makes Claude act on Home Assistant, and
those actions produce state changes, logbook entries and log records. A trigger
fired by Home Assistant's own output can therefore re-fire on the previous run's
consequences and keep going.

- `mode: single` drops a run that arrives while one is still executing.
- `max_exceeded: silent` stops that drop from writing a warning — the warning is
  itself a log record, and would be fuel for exactly the loop the guard exists
  to stop.
- The blueprint description now names the trigger types to avoid
  (`system_log_event`, error log, logbook, bare `state_changed`) and states what
  the Automation API's own limits do and don't cover: 10 requests/minute per
  caller and a single-execution mutex bound how often Claude actually runs, but
  not how often a runaway trigger fires.

Deliberately **no** template-based cooldown condition: a condition that can
raise (an unset `last_triggered`, a missing entity) logs an error on every
evaluation, which is the same hazard wearing a different costume. Both guards
are declarative and cannot fail.

The `rest_command.claude_terminal_query` dependency is unchanged — Home
Assistant only allows `rest_command` in `configuration.yaml`, so a blueprint
cannot define it — but the description now states plainly that the automation
fails with an unknown-service error without it.

### 🧪 The skills can't drift away from the tools

A skill describing a command that no longer exists is worse than no skill —
it sends Claude confidently at something that is not there. Three checks keep
them in step:

- `tests/test_scripts.sh` fails when any skill names an `ha-`/`claude-` command
  that `setup_commands` does not install, when frontmatter is malformed or a
  skill's `name` disagrees with its directory, and when the Dockerfile or
  `run.sh` stops shipping the skills at all.
- `ci/smoke.sh` asserts every expected skill is present in the built image with
  valid frontmatter — a skill missing from the image fails silently otherwise,
  because Claude simply never learns the command exists.
- The generated `~/.claude/CLAUDE.md` (`ha-context`) now lists the installed
  skills, so they are discoverable from always-loaded context.

## 2.5.1-wdn.13

### 🐛 Bug scrub of the wdn.10 / wdn.11 tooling

Every feature added in the last two releases shipped with at least one path that
could not work. Nothing here changes what the tools are for — it makes them do
what they already claimed to.

**Broken on arrival**
- **`esphome-setup` always failed.** A stray `EOF` line with no heredoc above it
  ran as a command, so the script exited 127 (`EOF: command not found`) after a
  successful install. It also registered the package with
  `persist-install --add-pip`, which is not a subcommand `persist-install`
  accepts — the call failed silently behind `|| true`, so ESPHome disappeared on
  the next restart despite the script announcing it had been persisted. It now
  installs *through* `persist-install`, which does both in one step.
- **The bundled automation blueprint still could not run.** wdn.12 fixed its
  stray `EOF`, so it parses — but it kept a hardcoded empty `trigger: []`, which
  means any automation built from it can never fire, and it pointed at
  `http://127.0.0.1:8128/api/query`: from Home Assistant Core's container
  `127.0.0.1` is Core rather than the add-on, and `/api/query` is not a route the
  API server serves. It now takes a trigger as an input, defaults to
  `http://claude_terminal_wdn:8128/api/prompt`, and the `rest_command` it depends
  on is documented in DOCS.md instead of being left to guesswork.
- **`claude-bot forward` never reached the API.** It posted to `/api/query`,
  which `claude-api-server.py` has never routed — every call got a 404. It also
  hardcoded port 8128, ignoring `automation_api_port`, and its help advertised a
  `setup` subcommand that fell through to the help text. All three fixed.

**Wrong behaviour**
- **`ha-validate --safe-edit` could not roll anything back.** It copied the file
  to `<file>.bak` *after* the edit, so "restoring" wrote the same broken content
  back. Rollback now needs a pre-edit snapshot: `ha-validate --backup <file>`
  before editing, `--safe-edit` after. Without a snapshot it says so plainly
  rather than reporting a restore that did nothing.
- **`ha-memory` ignored its `hours_back` argument.** Both date branches (BSD
  `-v`, GNU `-d "N hours ago"`) fail under the busybox `date` this image ships,
  leaving the start time empty and silently falling back to Home Assistant's own
  1-day window. The offset is now computed in the shell. Non-numeric input is
  rejected instead of being pasted into the URL.
- **`ha-dashboard` wrote unloadable YAML** when nothing matched, emitting a grid
  card with an empty `cards:` key. It now stops and explains.

**Safety**
- **`ha-git-backups rollback` ran `git reset --hard HEAD~1` on `/config` with no
  confirmation**, discarding the newest commit and every uncommitted change. It
  now lists exactly what will be lost, requires a typed confirmation (`--yes`
  for scripts), and refuses when there is no parent commit instead of failing
  with a git error.
- **The `.gitignore` it generates now excludes `secrets.yaml`**, plus
  `known_devices.yaml`, `ip_bans.yaml` and key material. `commit` runs
  `git add -A`, so every credential in the instance was previously written into
  git history inside `/config`. It also sets a fallback commit identity, so
  `commit` works without `git_user_name` / `git_user_email` configured.

**Automation API hardening**
- **Failed authentication is now rate limited.** The rate-limit check ran *after*
  the auth check, so a wrong token never reached it — the API token could be
  brute-forced at line speed by anything on the Docker bridge, with every attempt
  returning a clean 401. The limiter now runs first.
- `secrets_equal` uses `hmac.compare_digest`; the previous hand-rolled loop
  returned early on a length mismatch and was not constant-time despite saying so.
- A null `claude_extra_args` in `options.json` no longer raises inside the
  request handler.

**Tests**
- **The shell suite could not fail.** The `ha-scaffold` and `claude-cron` blocks
  ran inside `( … )` subshells, so their `FAILED` increments were discarded — 11
  of 29 assertions could print `[FAIL]` and still leave the suite exiting 0. The
  summary said 18 while 29 assertions ran.
- Added regression coverage for the bugs above: agreement between the API
  server's routes and its callers, and live-server tests for endpoint routing and
  brute-force rate limiting. wdn.12's blueprint YAML check is generalised to every
  file in `blueprints/` and given an `!input` constructor, so it tests YAML
  validity directly rather than depending on a Ruby interpreter being present to
  tolerate the unknown tag.

## 2.5.1-wdn.12

### 🐛 Fix Blueprint YAML Syntax Error
- Fixed trailing `EOF` string in `claude_automation_query.yaml` blueprint that caused Home Assistant to fail loading the blueprint.
- Updated `action:` key syntax for modern Home Assistant blueprint standards.
- Added automated YAML syntax validation for all add-on blueprints to `tests/test_scripts.sh`.

## 2.5.1-wdn.11

### 🚀 Next-Gen Advanced Capability Suite
- **`ha-dashboard`**: Lovelace YAML dashboard generator by area or entity domain.
- **`ha-mesh`**: Mesh network (Zigbee/Z-Wave/Matter) health inspector and low-battery scanner.
- **`ha-scaffold pyscript`**: Added PyScript automation handler generator (`ha-scaffold pyscript <name>`) under `/config/pyscript/`.
- **`ha-assist`**: Home Assistant Assist voice pipeline interface.
- **`ha-memory`**: Historical event and state transition query tool.
- **`claude-bot`**: Remote messaging gateway (Telegram, Matrix, Discord) for Claude Terminal.
- **`ha-git-backups`**: Automated `/config` git commits with 1-click `rollback` functionality.
- Updated `tmux` quick-bar (`Ctrl+B h`) and `welcome` banner listings.

## 2.5.1-wdn.10

### ✨ New Developer Utilities & Home Assistant Tools
- **`ha-snapshot`**: Camera vision helper script to capture camera frames (`camera.*`) via HA Supervisor API for Claude Code visual inspection.
- **`ha-validate`**: Home Assistant YAML configuration validator via `check_config` API with `--safe-edit <file>` automatic `.bak` safety rollbacks.
- **`ha-scaffold`**: Custom integration boilerplate generator (`manifest.json`, `config_flow.py`, `sensor.py`, `strings.json`, etc.) under `/config/custom_components/<domain>/`.
- **`esphome-setup`**: Persistent installation helper for ESPHome CLI toolchain.
- **`ha-tts`**: Text-to-speech announcement utility for Home Assistant media players.
- **`claude-cron`**: Scheduled autonomous task manager executing background `claude -p` prompts and notifying via HA persistent notifications.
- **`ha-diagnose`**: One-command health & system inspector summarizing container stats, YAML validation, entity domain counts, and recent error logs.
- **`tmux` Helper Menu (`Ctrl+B h`)**: Quick-bar popup menu in `tmux` for fast execution of diagnostics, validation, smart context refresh, and tips.
- **Home Assistant Blueprint**: Added `claude_automation_query.yaml` blueprint (auto-synced to `/config/blueprints/automation/`) to trigger Claude tasks via the Automation API.

### 🧪 Automated Unit Test Suite & QA Guardrails
- **Shell Unit Test Suite (`tests/test_scripts.sh`)**: Automated test runner covering CLI flags, option parsing, mock Supervisor API responses, scaffolding validation, and `claude-cron` JSON integrity.
- **Python API Unit Test Suite (`tests/test_api_server.py`)**: `unittest` suite for `claude-api-server.py` verifying trusted IP filtering, rate limiting, and binary discovery.
- **Local Validation Runner (`ci/local-validate.sh`)**: One-command developer check executing static linting (`shellcheck`), documentation drift check (`check-docs-drift.sh`), shell unit tests, and Python unit tests.
- **GitHub Actions CI Workflow (`unit-tests.yml`)**: Automated CI job executing unit tests on every pull request and push to `main`.

## 2.5.1-wdn.9

### 🔒 Cleared all 132 open code scanning alerts
The Security tab had accumulated 132 Trivy findings (1 CRITICAL, 47 HIGH, 60 MEDIUM, 23 LOW, 1 unrated) from two independent sources. Both are fixed at the image level, so the count goes to zero rather than being suppressed.

- **Removed `/usr/bin/tempio` — 67 findings, including the only CRITICAL.** `tempio` is a Go helper the Home Assistant base image ships for add-ons that render config files from their options at boot. This add-on renders nothing (every option is read through `bashio::config`, and `init: false` means there is no s6 stage either), so the binary was pure dead weight — but frozen at the base image's toolchain (Go 1.23.3 stdlib, `golang.org/x/crypto` v0.26.0) it carried 67 CVEs that no change in this repository could patch.
- **`apk upgrade` at build time — 65 findings.** Every outstanding OS-package CVE (`bind-libs`/`bind-tools`, `curl`/`libcurl`, `libcrypto3`/`libssl3`, `c-ares`) already had a fixed version published in the Alpine 3.23 branch; the image was simply shipping whatever the base image was built with. Builds now upgrade before installing, so a rebuild picks security fixes up on its own.

### 🚦 The security scan now gates instead of only reporting
`security-scan.yml` reported findings but never failed, which is how 132 alerts built up across an entirely green history. It now fails on a HIGH/CRITICAL that Alpine has already published a fix for — actionable by definition, since a rebuild resolves it. Vulnerabilities with no upstream fix stay visible in the job summary and Security tab without blocking unrelated pull requests. The gate runs last, so a failing scan still leaves a refreshed Security tab and a readable summary behind it.

No user-facing behaviour, options or credentials are affected.

## 2.5.1-wdn.8

### 📚 Terminology & App Store Updates
- Updated documentation and UI references across the project to match modern Home Assistant terminology ("Home Assistant apps", "App Store", "Settings → Apps → App Store").

## 2.5.1-wdn.7

### ✨ Automated OAuth Login Notifications & Terminal Mouse Fixes
- **Automated Login Link Notifications**: Added `claude-login-notifier` daemon running in the background. Automatically detects Claude Code sign-in OAuth URLs printed in tmux and posts a Home Assistant persistent notification with a direct Markdown hyperlink (`[👉 Authorize Claude Code]`). Automatically dismisses the notification once signed in.
- **Improved Terminal Copy/Click**: Added `tmux_mouse` configuration option, defaulting to `false`. Disabling `tmux` mouse mode enables native browser mouse text selection, standard system clipboard copy (`Ctrl+C` / `Cmd+C`), and direct single-click URL opening in the web terminal without mouse interception or `"copied XX chars to tmux buffer"` messages.

## 2.5.1-wdn.6

### 📚 Documentation & Agent Context Updates
- Updated repo-wide documentation (`CLAUDE.md`, `DEVELOPMENT.md`, `SECURITY.md`, `README.md`, `claude-terminal/README.md`).
- Enhanced `ha-context.sh` so the auto-generated `~/.claude/CLAUDE.md` context includes complete Automation API guidance, endpoints, and token details for Claude Code.

## 2.5.1-wdn.5

### ✨ Home Assistant Automation API
- Added HTTP Automation API daemon (`claude-api-server`) running on internal port `8128`.
- Enables Home Assistant automations, scripts, and blueprints to trigger Claude non-interactively (`claude -p "..."`).
- **Security controls**: Token authentication (`X-API-Key` or `Authorization: Bearer`), auto-generated 32-character API key (`/data/automation_api_token`), internal bridge network isolation (no host port published), IP subnet whitelisting, rate limiting (10 req/min), single process mutex lock, and safe parameterized subprocess execution.
- Added options `enable_automation_api`, `automation_api_port`, and `automation_api_key`.

## 2.5.1-wdn.4

### 🎨 Visual & Branding Updates
- Updated add-on `icon.png` and `logo.png` graphics to a modern flat vector design with a crisp Home Assistant sky blue theme.

## 2.5.1-wdn.3

### 🐛 Terminal loaded but never connected
2.5.1-wdn.2 could show the terminal panel and then sit on "Press Enter to
Reconnect" forever. The sign-in requirement introduced in the previous release
is enforced on the WebSocket connection as well as the page, and Home Assistant
only attaches the user identity to some ingress sessions — where it does not,
the page loads and the connection is refused, with nothing on screen explaining
why.

`require_ingress_user` now defaults to **off**, restoring the previous
behaviour. It remains available for anyone whose installation does pass the
identity through: turn it on, restart, and if the terminal stops connecting,
turn it back off.

While it is off, anyone with a Home Assistant account can open this terminal —
which is how the add-on has always behaved, and is documented in the security
notes.

## 2.5.1-wdn.2

### 🐛 Add-on failed to start (restart loop)
2.5.1-wdn.1 would install but never finish starting: Home Assistant reported
"Timeout while waiting for app to start", then the watchdog restarted it,
repeatedly.

Two changes in that release were mutually incompatible. The terminal began
requiring the Home Assistant sign-in header, and the new container health check
probed it *without* that header — so the probe got 401, the container never
reported healthy, and the watchdog kept restarting a terminal that was in fact
serving perfectly well the whole time.

The health check now sends the header. CI additionally asserts the container
reaches `healthy`, rather than only that the port answers — the previous test
sent the header itself, so it passed while the real health check failed.

## 2.5.1-wdn.1

First release of the WetDogNose fork of
[heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons).
No functional change to the add-on itself — this release repoints the build
and distribution pipeline at this repository.

- Images are built by this repo's CI and published to
  `ghcr.io/wetdognose/{arch}-addon-claude-terminal`, so what Home Assistant
  pulls is built from this tree rather than upstream's prebuilt binaries.
- Renamed to "Claude Terminal (WetDogNose)" with slug `claude_terminal_wdn`,
  so it installs alongside upstream's add-on instead of shadowing it.
- Publishing is now driven by `v*` tags rather than every push to `main`, so
  one tag maps to exactly one immutable image.
- Fork versions are `<upstream base>-wdn.<n>`, keeping the upstream release
  this is based on visible.

Upstream authorship is unchanged and credited in the image's
`org.opencontainers.image.authors` label.

### 🐛 HA Smart Context was writing where Claude never looks
`ha-context` generated its summary at `$HOME/CLAUDE.md`. Claude Code reads user
memory from `~/.claude/CLAUDE.md` and project memory from `./CLAUDE.md` upward
from the working directory — `$HOME/CLAUDE.md` is neither, so with
`ha_smart_context: true` the file was generated on every boot and never read.
It now writes `$HOME/.claude/CLAUDE.md`, so Claude actually knows your setup.

### ✨ Terminal no longer vanishes when Claude exits
Exiting Claude (`/exit`, Ctrl-D, or a crash) ended the tmux session, so the
browser panel went blank and took any error message with it. The launcher now
runs Claude as a child and drops you back to a shell afterwards, keeping the
scrollback and telling you the exit status.

### 🧹 `data-gc` for reclaiming /data
`/data` grows without bound: uv's wheel cache, uv's managed CPython, and a new
Claude version directory on every self-update. `data-gc` reports what is using
space and `data-gc clean` prunes caches and superseded versions. Credentials and
session history are never touched.

### ⚡ ha-mcp installed once instead of resolved per session
`uvx` re-resolved ha-mcp against the index on every MCP start, so a slow or
unreachable PyPI could delay or break Home Assistant tools on an add-on that
worked yesterday. It is now installed once into a persistent uv tool
environment.

### 🔧 Smaller footprint and phone-friendly terminal
tmux scrollback drops from 50,000 to 10,000 lines per pane — still five times
the tmux default, and considerably less resident memory on a Raspberry Pi — plus
status-bar and resize tuning for small screens. The bundled Claude Code version
can now be pinned at build time via a `CLAUDE_VERSION` build argument, making a
given source tree reproduce a byte-stable image.

### 🐙 GitHub built in
The [GitHub CLI](https://cli.github.com/) (`gh`) now ships in the image, so
Claude can manage your repositories — issues, pull requests, releases, Actions
runs — and push commits, without leaving Home Assistant.

Run `github-setup` once to sign in. It uses GitHub's device flow (a short URL
plus an 8-character code, so no clipboard truncation) and then runs
`gh auth setup-git`, which is the step that actually makes `git push` work.
Credentials live in `/data/.config/gh` and persist across restarts and add-on
updates.

Two new options, `git_user_name` and `git_user_email`, set the commit author
and are reapplied on every restart — git refuses to commit without them.
`claude-doctor` gained a GitHub section covering sign-in state, the credential
helper, the commit identity, and `api.github.com` reachability.

There is deliberately **no token option**: authentication is interactive so the
token never lands in `/data/options.json`, which is plaintext and visible in the
Home Assistant UI. It is still worth knowing that the token `gh` stores is
plaintext too (Alpine has no keyring) and that `/data` is included in backups —
see the GitHub section in the documentation before signing in.

## 2.5.1

### 🐛 Blank terminal when the persistent Claude build can't run
On containers built from older Alpine bases (musl < 1.2.5, which lacks
`posix_getdents`), recent native Claude Code builds abort on launch with
`Error relocating ...: posix_getdents: symbol not found` (#112).
Because the persistent install in `/data` is still executable, it kept
shadowing the working bundled copy on `PATH` — and since ttyd launches
`tmux new-session ... 'claude'`, the tmux session died the instant `claude`
did, leaving users with a blank/immediately-closing terminal. Self-healing
auto-update never recovered either, because updating requires running the
broken binary.

Startup now verifies the persistent build **actually runs** (not just that
it's present and `+x`); if it can't, the broken install is removed so the
bundled copy takes over and the terminal stays usable. This runs even when
`claude_auto_update` is disabled (disabling updates never removed the broken
binary), and a background `claude update` that pulls an unrunnable build is
now re-validated and rolled back the same way.

Contributed by [@JoshDev](https://github.com/JoshDev) (#117); thanks
[@Dezent](https://github.com/Dezent) for the diagnosis in #112.

### 🔧 Bundled Claude now installed as a native binary at build time
The `@anthropic-ai/claude-code` npm package has become a thin wrapper that
just installs the platform's native binary, and running npm/Node during
QEMU-emulated aarch64 image builds started crashing CI. The Dockerfile now
downloads the native musl binary directly from the npm registry (curl+tar,
no Node involved) and places it at `/usr/local/bin/claude`. Same
"latest at build time" behavior, smaller image, and aarch64 images build
reliably again.

## 2.5.0

### 📦 Prebuilt images
Installs and updates now pull prebuilt images from GHCR
(`ghcr.io/heytcass/{arch}-addon-claude-terminal`) instead of building
locally on your Home Assistant box. This means:
- **No more build OOM failures on small systems** (#56)
- **The add-on image is no longer exported into HA backups** — combined with
  the 2.3.0 npm-cache fix, this fully resolves the backup bloat report (#103)
- Much faster installs and updates

### ⚠️ Breaking: armv7 (32-bit ARM) support dropped
Home Assistant's builder and HAOS have dropped 32-bit ARM, and neither
native Claude Code builds nor uv-managed Python exist for it. Existing
armv7 installs keep working on 2.4.x but won't be offered this update.
aarch64 (Raspberry Pi 3/4/5 on 64-bit HAOS) is fully supported.

### 🛠️ Cleanup
- Removed now-dead 32-bit ARM fallback paths from startup and MCP setup
- Fixed the `image.source` label to point at this repository

## 2.4.0

### ✨ ha-mcp 3.5.1 → 7.11.0 (four major versions)
The bundled Home Assistant MCP server was pinned to 3.5.1 for a structural
reason: every later release requires CPython 3.13 exactly, which no Alpine
release ships, and Alpine's packaged uv was too old to install managed musl
Python builds. Approach adapted from #104 by [@WKassebaum](https://github.com/WKassebaum):

- uv is now installed from PyPI (pinned 0.11.28) and provisions a managed
  musl CPython 3.13 under `/data` (downloads once, persists)
- ha-mcp launches via `uvx --python 3.13`; the environment is pre-warmed in
  the background so the first MCP connection doesn't hit the startup timeout
- **Fixes the "WebSocket not connected" tool failures** (#95) — ha-mcp 7.x
  reworked its WebSocket layer
- **Fixes the numpy x86_v2 crash on older CPUs** (#76) — ha-mcp 7.x dropped
  the numpy/textdistance dependency entirely
- New `ha_mcp_version` option (default `"7.11.0"`) so future bumps are a
  config change, not a release
- 32-bit ARM (armv7) stays on ha-mcp 3.5.1 (no managed musl Python builds)

Note: the managed Python and MCP environment add roughly 150–250 MB under
`/data`, which is included in HA backups. This is a one-time cost, not
unbounded growth like the old npm cache.

### 🛠️ CI/CD
- New Publish Images workflow: builds and pushes per-arch images to GHCR on
  every release. Groundwork for prebuilt installs (no more local builds,
  build OOM (#56), or image blobs in backups) — activated in a follow-up
  release once the packages are public.

## 2.3.2

### 🐛 Bug Fixes
- **New `claude-login-url` command**: saves the OAuth login URL to
  `/config/claude-login-url.txt` so it can be copied via the File Editor or
  Samba. The browser terminal's OSC 52 clipboard path truncates payloads at
  roughly 400 characters — shorter than the login URL — which cut off the
  `state` parameter and made authorization fail with "Invalid request format".
  This gives login a path that bypasses the terminal clipboard entirely.
- **Auth status indicator now checks token expiry**: a leftover credentials
  file with an expired token shows orange instead of green

## 2.3.1

### 🐛 Bug Fixes
- **Fixed copying (including the OAuth login URL) not reaching the clipboard**:
  ttyd's `xterm-256color` terminfo lacks the `Ms` capability, so tmux never
  actually emitted OSC 52 — mouse-drag copies landed in tmux's internal buffer
  only, which broke the first-login flow introduced alongside 2.3.0's mouse
  mode. tmux is now told the OSC 52 escape sequence explicitly; drag-copy and
  Claude's login "press `c` to copy" both reach the browser clipboard (HTTPS
  required by browsers), and wrapped URLs are copied as a single joined line
- Documented Shift+drag (native browser selection, bypasses tmux) as the
  fallback for plain-`http://` access, plus a login troubleshooting section

## 2.3.0

Back to basics: the add-on's job is Claude Code in a terminal, done reliably.
This release removes the wrapper layers, makes startup network-independent,
and keeps Claude Code itself up to date.

### ✨ New Features
- **Claude Code auto-update** (`claude_auto_update`, default `true`): installs the
  official native Claude Code build into `/data` on first boot and refreshes it in
  the background on every startup. No more being frozen at whatever version was
  current when the image was built (#102). Adapted from #104 by [@WKassebaum](https://github.com/WKassebaum). 32-bit ARM keeps the bundled npm copy (no native builds available).
- **`dangerously_skip_permissions`** (default `false`): launches Claude with
  `--dangerously-skip-permissions`. A prominent warning is logged at startup;
  read the security note in DOCS before enabling (#51, #97, #104 — thanks
  [@alexcf](https://github.com/alexcf), [@monxas](https://github.com/monxas), [@WKassebaum](https://github.com/WKassebaum))
- **`claude_extra_args`**: extra flags appended to every Claude launch
  (e.g. `--model`, `--verbose`)
- **Broader file access**: `/addon_configs` and `/share` are now mapped, so Claude
  can help with other add-ons' configuration (#21, #40)

### 🐛 Bug Fixes
- **Backup bloat fixed** (#103): the npm cache now lives in `/tmp` instead of
  persistent storage, and the old multi-GB cache in `/data/home/.npm` is cleaned up
  on first boot. Thanks [@dschaedl](https://github.com/dschaedl) for the diagnosis.
- **Scrollback works** (#55, #82): tmux mouse mode is now enabled under ttyd, so the
  mouse wheel scrolls history and drag-select copies to the browser clipboard via OSC 52
- **Offline/flaky-network startup**: ttyd, tmux, and jq are baked into the image
  instead of being apk-installed on every boot — the terminal now starts with no
  network at all
- **`IS_SANDBOX=1`** is set in the image, fixing silent Claude exits when permission
  skipping is used as root (#87 — thanks [@MrJester](https://github.com/MrJester))
- Auth indicator in the tmux status bar now recognizes current Claude Code
  credential locations (`~/.claude/.credentials.json`)

### 🔥 Removed (simplification)
- **Session picker**: `auto_launch_claude: false` now drops to a plain shell with a
  short command cheatsheet. Claude Code's own `-c` / `-r` flags cover
  continue/resume, and tmux already handles reconnects
- **"Press Enter to continue" welcome gate**: the banner no longer blocks; in
  auto-launch mode Claude opens immediately
- **Authentication helper menu**: modern Claude Code handles OAuth itself
- **Boot-time health check**: no more network probes delaying startup; run
  `claude-doctor` in the terminal for on-demand diagnostics
- HA context generation now runs in the background instead of blocking startup

## 2.2.2

### 🐛 Bug Fixes
- **Fixed ha-mcp installation on Python 3.12** (#79): Added `--index-strategy unsafe-best-match` to uvx invocations to resolve package resolution failures when the HA wheels index lacks compatible wheels for the current Python version
  - Contributed by [@tt2g89](https://github.com/tt2g89)

### 🛠️ CI/CD
- Added automated build and smoke test workflow for pull requests
  - Dockerfile linting via hadolint
  - Container builds verified for amd64 and aarch64
  - Smoke tests for script executability and required binaries
  - Required status checks prevent merging broken PRs

## 2.2.1

### 🛠️ Configuration
- Disable remote access port 7681 by default

### 🔒 Security Note
The default configuration enabled unauthenticated access on the local network. For users who have not customized the port setting, direct access on port 7681 is now disabled by default. Access through Home Assistant (ingress) is not affected by this change. Users who need direct port access can re-enable it in the add-on configuration.

## 2.2.0

### ✨ New Features
- **Bundled Home Assistant MCP Server** (#48): Claude Code now has native Home Assistant integration
  - Switched to [homeassistant-ai/ha-mcp](https://github.com/homeassistant-ai/ha-mcp) - the comprehensive HA MCP server
  - 97+ tools for entity control, automations, scripts, dashboards, history, and more
  - Automatic configuration using Supervisor API - no manual token setup required
  - Natural language control: "Turn off the living room lights", "Create an automation for sunset"
  - New `enable_ha_mcp` configuration option (enabled by default)
  - Contributed by [@brianegge](https://github.com/brianegge)

### 🛠️ Configuration
Enable or disable the Home Assistant MCP integration in your add-on config:
```yaml
enable_ha_mcp: true  # default
```

### 📦 Technical Details
- Uses `uvx ha-mcp@3.5.1` for automatic package management and Python version handling
- Installed [uv](https://github.com/astral-sh/uv) via Alpine package for fast Python package execution
- MCP server connects to Home Assistant via internal Supervisor API (`http://supervisor/core`)
- Authentication uses the add-on's Supervisor token automatically

### 🔒 Security Note
The ha-mcp integration gives Claude extensive control over your Home Assistant instance, including the ability to control devices, modify automations, and access history data. You can disable it at any time by setting `enable_ha_mcp: false`.

### 💬 Example Usage
Once configured, you can ask Claude things like:
- "What's the current state of my thermostat?"
- "Turn on the porch lights"
- "Create an automation that turns on the coffee maker at 7 AM"
- "Show me the energy usage for the last week"
- "Debug why my motion sensor automation isn't working"

## 2.1.0

### ✨ New Features
- **Smart Status Bar**: tmux status bar now shows live system indicators
  - Auth status: green when authenticated, red when credentials are missing
  - Home Assistant connection: green when connected, yellow on issues
  - "Claude Terminal" identity label on the left side
  - Auto-refreshes every 15 seconds
- **Terminal Theme**: Dark, polished color scheme applied to the web terminal
  - Terracotta (#d97757) accent color for cursor and UI highlights
  - Improved contrast and readability with 14px font size
  - Matching tmux pane borders and window status colors

### 🎨 Visual Improvements
- Redesigned welcome banner with terracotta-accented borders and breathing room
- Redesigned session picker banner with matching branded style
- Dynamic version padding prevents box-drawing misalignment
- Cohesive color language across terminal theme, tmux, and banners

## 2.0.0

### ✨ New Features
- **HA Smart Context**: Claude automatically knows your Home Assistant setup
  - Generates a context file with system info, entity counts, installed add-ons, and recent errors
  - Claude Code loads this automatically — no configuration needed
  - Run `ha-context` to refresh, `ha-context --full` for detailed entity listings
  - New `ha_smart_context` config option (default: true) to enable/disable
  - Queries Supervisor + Core APIs: entities by domain, error log, system health
- **Welcome Screen**: Polished first-launch experience with version tracking
  - Styled banner displayed on every terminal open
  - "What's New" highlights shown once per version upgrade
  - Version tracking persisted across restarts

### 🎯 User Experience
- Every Claude session now has context about your HA environment out of the box
- Ask Claude about your entities, automations, or errors — it already knows

### 💙 Thank You
To everyone who stuck with me through the v1.6–1.9 rough patch — the musl binary issues, the nested tmux errors, the auth helper breakage — thank you for your patience, your bug reports, and your trust. This release is dedicated to you. I heard every issue, and I'm committed to making Claude Terminal the best it can be.

## 1.9.0

### 🔄 Changed
- **Reverted to npm installation**: Switched back from native installer to `npm install -g @anthropic-ai/claude-code`
  - Native binary requires musl 1.2.6+ (`posix_getdents` symbol), which Alpine 3.21 does not ship
  - npm installation runs on Node.js, avoiding all musl binary compatibility issues
  - Resolves #57, #60, #61
- **Removed native binary symlink logic** from `run.sh` (no longer needed with npm install)

## 1.7.0

### ✨ New Features
- **Session Persistence with tmux** (#46): Claude sessions now survive browser navigation
  - Sessions persist when navigating away from the terminal in Home Assistant
  - New "Reconnect to existing session" option in session picker (option 0)
  - Seamless session resumption - conversations continue exactly where you left off
  - tmux integration provides robust session management
  - Contributed by [@petterl](https://github.com/petterl)

### 🛠️ Technical Details
- Added tmux package to container
- Custom tmux configuration optimized for web terminals:
  - Mouse mode intelligently disabled when using ttyd (prevents conflicts)
  - OSC 52 clipboard support for copy/paste to browser
  - 50,000 line history buffer for extensive scrollback
  - Vi-style keybindings in copy mode
  - Visual improvements with better status bar
- Session picker enhanced with reconnection logic
- Automatic session cleanup and management

### 🎯 User Experience
- No more lost work when switching between Home Assistant pages
- Browser refresh no longer interrupts Claude conversations
- Tab switching preserves full session state including history
- Improved reliability for long-running Claude sessions

## 1.6.1

### 🐛 Bug Fix - Native Install Path Mismatch
- **Fixed "installMethod is native, but directory does not exist" error**: Claude binary now available at `$HOME/.local/bin/claude` at runtime
  - **Root cause**: Native installer places Claude at `/root/.local/bin/claude` during Docker build, but at runtime `HOME=/data/home`, so Claude's self-check looks in `/data/home/.local/bin/claude` which didn't exist
  - **Solution**: Symlink created from `/data/home/.local/bin/claude` → `/root/.local/bin/claude` on startup
  - **Result**: Claude native binary resolves correctly regardless of HOME directory change
  - Ref: [ESJavadex/claude-code-ha#3](https://github.com/ESJavadex/claude-code-ha/issues/3)

## 1.6.0 - 2026-01-26

### 🔄 Changed
- **Native Claude Code Installation**: Switched from npm package to official native installer
  - Uses `curl -fsSL https://claude.ai/install.sh | bash` instead of `npm install -g @anthropic-ai/claude-code`
  - Native binary provides automatic background updates from Anthropic
  - Faster startup (no Node.js interpreter overhead)
  - Claude binary symlinked to `/usr/local/bin/claude` for easy access
- **Simplified execution**: All scripts now call `claude` directly instead of `node $(which claude)`
- **Cleaner Dockerfile**: Removed npm retry/timeout configuration (no longer needed)

### 📦 Notes
- Node.js and npm remain available as development tools
- Existing authentication and configuration files are unaffected

## 1.5.0

### ✨ New Features
- **Persistent Package Management** (#32): Install APK and pip packages that survive container restarts
  - New `persist-install` command for installing packages from the terminal
  - Configuration options: `persistent_apk_packages` and `persistent_pip_packages`
  - Packages installed via command or config are automatically reinstalled on startup
  - Supports both Home Assistant add-on config and local state file
  - Inspired by community contribution from [@ESJavadex](https://github.com/ESJavadex)

### 📦 Usage Examples
```bash
# Install APK packages persistently
persist-install apk vim htop

# Install pip packages persistently
persist-install pip requests pandas numpy

# List all persistent packages
persist-install list

# Remove from persistence (package remains until restart)
persist-install remove apk vim
```

### 🛠️ Configuration
Add to your add-on config to auto-install packages:
```yaml
persistent_apk_packages:
  - vim
  - htop
persistent_pip_packages:
  - requests
  - pandas
```

## 1.4.1

### 🐛 Bug Fixes
- **Actually include Python and development tools** (#30): Fixed Dockerfile to include tools documented in v1.4.0
  - Resolves #27 (Add git to container)
  - Resolves #29 (v1.4.0 missing Python and development tools)
- **Added yq**: YAML processor for Home Assistant configuration files

## 1.4.0

### ✨ New Features
- **Added Python and development tools** (#26): Enhanced container with scripting and automation capabilities
  - **Python 3.11** with pip and commonly-used libraries (requests, aiohttp, yaml, beautifulsoup4)
  - **git** for version control
  - **vim** for advanced text editing
  - **jq** for JSON processing (essential for API work)
  - **tree** for directory visualization
  - **wget** and **netcat** for network operations

### 📦 Notes
- Image size increased from ~300 MB to ~457 MB (+52%) to accommodate new tools

## 1.3.2

### 🐛 Bug Fixes
- **Improved installation reliability** (#16): Enhanced resilience for network issues during installation
  - Added retry logic (3 attempts) for npm package installation
  - Configured npm with longer timeouts for slow/unstable connections
  - Explicitly set npm registry to avoid DNS resolution issues
  - Added 10-second delay between retry attempts

### 🛠️ Improvements
- **Enhanced network diagnostics**: Better troubleshooting for connection issues
  - Added DNS resolution checks to identify network configuration problems
  - Check connectivity to GitHub Container Registry (ghcr.io)
  - Extended connection timeouts for virtualized environments
  - More detailed error messages with specific solutions
- **Better virtualization support**: Improved guidance for VirtualBox and Proxmox users
  - Enhanced VirtualBox detection with detailed configuration requirements
  - Added Proxmox/QEMU environment detection
  - Specific network adapter recommendations for VM installations
  - Clear guidance on minimum resource requirements (2GB RAM, 8GB disk)

## 1.3.1

### 🐛 Critical Fix
- **Restored config directory access**: Fixed regression where add-on couldn't access Home Assistant configuration files
  - Re-added `config:rw` volume mapping that was accidentally removed in 1.2.0
  - Users can now properly access and edit their configuration files again

## 1.3.0

### ✨ New Features
- **Full Home Assistant API Access**: Enabled complete API access for automations and entity control
  - Added `hassio_api`, `homeassistant_api`, and `auth_api` permissions
  - Set `hassio_role` to 'manager' for full Supervisor access
  - Created comprehensive API examples script (`ha-api-examples.sh`)
  - Includes Supervisor API, Core API, and WebSocket examples
  - Python and bash code examples for entity control

### 🐛 Bug Fixes
- **Fixed authentication paste issues** (#14): Added authentication helper for clipboard problems
  - New authentication helper script with multiple input methods
  - Manual code entry option when clipboard paste fails
  - File-based authentication via `/config/auth-code.txt`
  - Integrated into session picker as menu option

### 🛠️ Improvements
- **Enhanced diagnostics** (#16): Added comprehensive health check system
  - System resource monitoring (memory, disk space)
  - Permission and dependency validation
  - VirtualBox-specific troubleshooting guidance
  - Automatic health check on startup
  - Improved error handling with strict mode

## 1.2.1

### 🔧 Internal Changes
- Fixed YAML formatting issues for better compatibility
- Added document start marker and fixed line lengths

## 1.2.0

### 🔒 Authentication Persistence Fix (PR #15)
- **Fixed OAuth token persistence**: Tokens now survive container restarts
  - Switched from `/config` to `/data` directory (Home Assistant best practice)
  - Implemented XDG Base Directory specification compliance
  - Added automatic migration for existing authentication files
  - Removed complex symlink/monitoring systems for simplicity
  - Maintains full backward compatibility

## 1.1.4

### 🧹 Maintenance
- **Cleaned up repository**: Removed erroneously committed test files (thanks @lox!)
- **Improved codebase hygiene**: Cleared unnecessary temporary and test configuration files

## 1.1.3

### 🐛 Bug Fixes
- **Fixed session picker input capture**: Resolved issue with ttyd intercepting stdin, preventing proper user input
- **Improved terminal interaction**: Session picker now correctly captures user choices in web terminal environment

## 1.1.2

### 🐛 Bug Fixes
- **Fixed session picker input handling**: Improved compatibility with ttyd web terminal environment
- **Enhanced input processing**: Better handling of user input with whitespace trimming
- **Improved error messages**: Added debugging output showing actual invalid input values
- **Better terminal compatibility**: Replaced `echo -n` with `printf` for web terminals

## 1.1.1

### 🐛 Bug Fixes  
- **Fixed session picker not found**: Moved scripts from `/config/scripts/` to `/opt/scripts/` to avoid volume mapping conflicts
- **Fixed authentication persistence**: Improved credential directory setup with proper symlink recreation
- **Enhanced credential management**: Added proper file permissions (600) and logging for debugging
- **Resolved volume mapping issues**: Scripts now persist correctly without being overwritten

## 1.1.0

### ✨ New Features
- **Interactive Session Picker**: New menu-driven interface for choosing Claude session types
  - 🆕 New interactive session (default)
  - ⏩ Continue most recent conversation (-c)
  - 📋 Resume from conversation list (-r) 
  - ⚙️ Custom Claude command with manual flags
  - 🐚 Drop to bash shell
  - ❌ Exit option
- **Configurable auto-launch**: New `auto_launch_claude` setting (default: true for backward compatibility)
- **Added nano text editor**: Enables `/memory` functionality and general text editing

### 🛠️ Architecture Changes
- **Simplified credential management**: Removed complex modular credential system
- **Streamlined startup process**: Eliminated problematic background services
- **Cleaner configuration**: Reduced complexity while maintaining functionality
- **Improved reliability**: Removed sources of startup failures from missing script dependencies

### 🔧 Improvements
- **Better startup logging**: More informative messages about configuration and setup
- **Enhanced backward compatibility**: Existing users see no change in behavior by default
- **Improved error handling**: Better fallback behavior when optional components are missing

## 1.0.2

### 🔒 Security Fixes
- **CRITICAL**: Fixed dangerous filesystem operations that could delete system files
- Limited credential searches to safe directories only (`/root`, `/home`, `/tmp`, `/config`)
- Replaced unsafe `find /` commands with targeted directory searches
- Added proper exclusions and safety checks in cleanup scripts

### 🐛 Bug Fixes
- **Fixed architecture mismatch**: Added missing `armv7` support to match build configuration
- **Fixed NPM package installation**: Pinned Claude Code package version for reliable builds
- **Fixed permission conflicts**: Standardized credential file permissions (600) across all scripts
- **Fixed race conditions**: Added proper startup delays for credential management service
- **Fixed script fallbacks**: Implemented embedded scripts when modules aren't found

### 🛠️ Improvements
- Added comprehensive error handling for all critical operations
- Improved build reliability with better package management
- Enhanced credential management with consistent permission handling
- Added proper validation for script copying and execution
- Improved startup logging for better debugging

### 🧪 Development
- Updated development environment to use Podman instead of Docker
- Added proper build arguments for local testing
- Created comprehensive testing framework with Nix development shell
- Added container policy configuration for rootless operation

## 1.0.0

- First stable release of Claude Terminal add-on:
  - Web-based terminal interface using ttyd
  - Pre-installed Claude Code CLI
  - User-friendly interface with clean welcome message
  - Simple claude-logout command for authentication
  - Direct access to Home Assistant configuration
  - OAuth authentication with Anthropic account
  - Auto-launches Claude in interactive mode
