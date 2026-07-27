# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Home Assistant add-on repository containing one add-on: **Claude Terminal** — Claude Code CLI in a browser terminal (ttyd + tmux). The design goal is to stay thin: the add-on's job is running Claude Code reliably, not wrapping it in extra UI.

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
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.21 \
  -t local/claude-terminal ./claude-terminal

# Lint — both run in CI and must stay clean
hadolint ./claude-terminal/Dockerfile          # error threshold; DL3006/DL3018 ignored in CI
shellcheck -s bash -e SC1008 -e SC1091 claude-terminal/run.sh claude-terminal/scripts/*.sh

# Run locally + check
podman run -p 7681:7681 -v $(pwd)/config:/config local/claude-terminal
curl -X GET http://localhost:7681/
```

There is **no unit/integration test suite.** Verification is: lint + a container build + smoke tests (see CI below) + manual testing in a container. Changing behavior means running it, not running tests.

## Architecture

### Add-on structure (`claude-terminal/`)
- **config.yaml** — options schema, ingress, volume maps, `image:` (prebuilt GHCR image), and the **version string that drives releases**
- **Dockerfile** — Alpine-based; all runtime packages (ttyd, tmux, nodejs, uv, ...) are baked in so startup never depends on the network
- **build.yaml** — base images per arch (amd64, aarch64) + OCI labels, consumed by `home-assistant/builder`
- **run.sh** — the boot path: environment/persistence setup, background Claude update, ttyd launch
- **scripts/** — copied to `/opt/scripts/`; `run.sh` installs most of them into `/usr/local/bin` under friendlier names

### Container execution flow (`run.sh` `main()`)
1. `init_environment` — point HOME/XDG at `/data` (persistent), prepend `/data/home/.local/bin` to PATH, clean legacy npm cache, migrate legacy credentials, install `.tmux.conf`
2. `setup_commands` — install `welcome`, `persist-install`, `ha-context`, `claude-doctor` (health-check.sh), `claude-login-url`, `github-setup` into `/usr/local/bin`; write the add-on version to `/opt/scripts/addon-version` (bashio isn't available inside ttyd)
3. `update_claude` — validate/repair the persistent native install, then background install/update into `/data`
4. `install_persistent_packages` — apk/pip packages from add-on options **and** `/data/persistent-packages.json` (written by `persist-install`)
5. `configure_git` — sets the global commit identity from options, and runs `gh auth setup-git` **only if** `$XDG_CONFIG_HOME/gh/hosts.yml` exists. Gated on the file, not on `gh auth status`, because that would put a network call on the boot path
6. `generate_ha_context` — background CLAUDE.md generation via the Supervisor API
7. `setup_ha_mcp` — sourced, then `configure_ha_mcp_server` registers ha-mcp with `claude mcp add`
8. `start_web_terminal` — `exec ttyd ... tmux new-session -A -s claude 'claude [flags]'` (or `welcome --shell` when `auto_launch_claude: false`)

### Key design rules
- **Nothing on the boot path may hit the network or block on input.** Network work (updates, context generation, MCP pre-warm) is backgrounded; packages ship in the image.
- **Everything persistent lives in `/data`** (HOME is `/data/home`). The container filesystem is recreated on every restart.
- **`/data` is included in HA backups** — never let caches or reproducible artifacts accumulate there (this is why `npm_config_cache=/tmp/npm-cache`).
- **Two Claude copies exist**: the native musl binary baked into the image at `/usr/local/bin/claude` (fallback, frozen at build time, fetched straight from the npm registry — no npm/Node during build, which crashes under QEMU in aarch64 CI builds) and the native install in `/data/home/.local/bin` (persists, self-updates, wins via PATH).
- **"Installed" and "actually runs" are separate facts.** A persistent native build can be `+x` yet abort on launch (musl symbol mismatch, e.g. `posix_getdents`). Because ttyd runs `tmux new-session ... 'claude'`, a broken binary kills the tmux session instantly and the user sees a blank terminal. `run.sh` probes with `timeout 10 claude --version` and deletes the install if it fails — **unconditionally, even when `claude_auto_update` is off**, and again after any background update. Don't regress this into a bare `-x` check.
- **Never let a non-essential step kill startup.** `set -e` is on, so intentional non-zero returns must be captured (`ensure_native_claude_usable || native_usable=$?`), not left bare.
- **No custom session UI.** tmux `new-session -A` handles reconnects; Claude Code's own `-c`/`-r` handle continue/resume.

### Options → consumers
All options are read via `bashio::config` (from `/data/options.json`):

| Option | Read by |
|---|---|
| `auto_launch_claude` | `get_claude_launch_command` |
| `claude_auto_update` | `update_claude` |
| `dangerously_skip_permissions`, `claude_extra_args` | `build_claude_flags` (word-split; quoted multi-word args are a documented limitation) |
| `ha_smart_context` | `generate_ha_context` |
| `enable_ha_mcp`, `ha_mcp_version` | `scripts/setup-ha-mcp.sh` |
| `git_user_name`, `git_user_email` | `configure_git` |
| `persistent_apk_packages`, `persistent_pip_packages` | `install_persistent_packages` |

### Notable subsystem constraints
- **ha-mcp** requires CPython 3.13 exactly; Alpine 3.21 ships 3.12, so `uvx --python 3.13` provisions a managed musl build into `/data` (hence the pinned `uv==0.11.28` from PyPI — Alpine's apk `uv` can't do this). `--index-strategy unsafe-best-match` is required for the HA wheels index.
- **Clipboard**: ttyd advertises `TERM=xterm-256color`, whose terminfo lacks `Ms`, so `tmux.conf` teaches tmux the OSC 52 escape explicitly. OSC 52 truncates around ~400 chars, which is shorter than Claude's OAuth login URL — that's the entire reason `claude-login-url` exists (it `capture-pane -J`s the URL out of the session into `/config`).
- **tmux status bar** shells out to `scripts/tmux-status.sh` every 15s; it must stay fast (<1s) and needs no bashio.
- **GitHub** is the `gh` CLI from Alpine community (no MCP server). Credentials persist for free because `gh` reads `$XDG_CONFIG_HOME/gh` and `init_environment` already points `XDG_CONFIG_HOME` at `/data/.config` — don't add persistence code for it. Authentication is interactive (`github-setup`) by design: there is no token option, because `/data/options.json` is plaintext and rides along in HA backups.

### Script conventions
- `#!/usr/bin/with-contenv bashio` for boot-path scripts (`run.sh`, `setup-ha-mcp.sh`, `health-check.sh`, `persist-install.sh`)
- plain `#!/bin/bash` for scripts that run inside the user's terminal (`welcome.sh`, `ha-context.sh`, `tmux-status.sh`, `claude-login-url.sh`, `github-setup.sh`) — **no bashio there**; ttyd's environment doesn't provide it
- 4-space indent in shell, 2-space in YAML; credential files get 600 permissions
- Errors report via `bashio::log.error` / `bashio::log.warning` and continue

## CI & Release

Workflows in `.github/workflows/`:
- **build-test.yml** (PRs touching `claude-terminal/**`) — hadolint + amd64/aarch64 builds, then amd64 smoke tests asserting specific scripts are executable and specific binaries exist. **Adding a script to `scripts/` or a required binary means updating the lists in this workflow.**
- **shellcheck.yml** (PRs touching `*.sh`) — severity `warning`, `-e SC1008 -e SC1091`
- **security-scan.yml** — Trivy HIGH/CRITICAL, on Dockerfile/run.sh PRs and weekly
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
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.21 \
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

Outside a real Supervisor, `bashio::config` falls back to defaults and Supervisor-API steps (HA context, MCP, `SUPERVISOR_TOKEN`) no-op — don't read their absence as a bug. Run `claude-doctor` inside the terminal for environment/network diagnostics.

## Important Constraints

- Targets Home Assistant OS (Alpine base); **amd64 + aarch64 only** — armv7 was dropped in 2.5.0
- Credential/session persistence must survive container restarts and add-on updates
- Key env vars: `HOME=/data/home`, `ANTHROPIC_CONFIG_DIR=/data/.config/claude`, `ANTHROPIC_HOME=/data`, `IS_SANDBOX=1` (image env — lets Claude accept `--dangerously-skip-permissions` as root), `npm_config_cache=/tmp/npm-cache` (image env)
