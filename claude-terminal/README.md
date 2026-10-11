# Claude Terminal for Home Assistant (WetDogNose fork)

Claude Code in a web terminal, as a Home Assistant app.

A fork of [heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons) — see [Upstream & attribution](#upstream--attribution).

![Claude Terminal Screenshot](https://github.com/WetDogNose/home-assistant-claude/raw/main/claude-terminal/screenshot.png)

*Claude Terminal running in Home Assistant*

## What is Claude Terminal?

This app runs Anthropic's [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI in a browser-based terminal, directly from your Home Assistant dashboard. It starts in your `/config` directory, so Claude can immediately help with:

- Writing and debugging automations, scripts, and dashboards
- Fixing YAML configuration problems
- Controlling and inspecting Home Assistant via the bundled MCP server
- General coding and troubleshooting

## Features

- **Just Claude Code**: opens straight into Claude — no menus in the way
- **OpenCode as a second agent**: [OpenCode](https://opencode.ai/) in window 2 (`Ctrl+B 2`), pointed at any API endpoint or local model with `opencode-config` — or by asking Claude to set it up
- **Claude can drive OpenCode**: ask Claude to set OpenCode up, or to hand it a task and read back the answer — see [How Claude and OpenCode fit together](DOCS.md#how-claude-and-opencode-fit-together)
- **Automation API & Blueprints**: HTTP daemon (port 8128) and four HA blueprints for non-interactive Claude prompts, synchronous or as background jobs
- **Notifications & entities**: Home Assistant tells you when Claude finishes or is waiting, and sees both agents as `claude_terminal_*` / `opencode_*` entities
- **Phone key bar**: Esc, Tab, Ctrl and cursor keys on touch devices
- **Several sessions & usage**: `claude-session` runs more than one Claude at once; `claude-usage` reports token use
- **Built-in skills**: Claude already knows how to use the add-on's own commands
- **Dashboard Generator**: `ha-dashboard` generates Lovelace YAML dashboards by area or entity domain
- **Mesh & Battery Inspector**: `ha-mesh` scans Zigbee/Z-Wave/Matter signal quality and low battery levels
- **PyScript & Integration Scaffolding**: `ha-scaffold` generates custom integrations or PyScript Python automations
- **HA Assist Integration**: `ha-assist` queries Home Assistant Assist voice pipeline
- **State History Search**: `ha-memory` queries state transitions and event history
- **Remote Messaging Bot**: `claude-bot` connects Telegram/Matrix/Discord webhooks to Claude
- **Git Time-Machine**: `ha-git-backups` commits `/config` with 1-click `rollback` functionality
- **YAML Guardrails & Validation**: `ha-validate` utility checks configuration via HA API and auto-restores `.bak` on error
- **Camera Vision**: `ha-snapshot` captures camera frames for Claude visual analysis
- **Dev & ESPHome Tools**: `esphome-setup` installs & persists ESPHome CLI
- **Autonomous Scheduler**: `claude-cron` runs prompts on a cron schedule, `daily 07:00` or `every 30m`, and posts HA notifications
- **Quick-Bar & Diagnostics**: `ha-diagnose` for one-command system health; `Ctrl+B h` popup menu in tmux
- **Stays current**: the official native Claude Code build is installed into persistent storage and auto-updated in the background
- **Session persistence**: tmux keeps your conversation alive across browser reloads and HA navigation; scrollback and mouse copy work
- **Persistent auth**: log in once via OAuth; credentials survive restarts and updates
- **Home Assistant MCP**: bundled [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) server for natural-language control of your instance
- **GitHub built in**: the `gh` CLI is included — run `github-setup` once and Claude can manage issues, PRs and releases, and push commits
- **HA Smart Context**: Claude automatically knows your HA version, entities, and apps
- **Broad file access**: `/config`, `/addon_configs`, and `/share` are mounted
- **Persistent packages**: `persist-install` keeps your extra apk/pip tools across restarts
- **Multi-architecture**: amd64 and aarch64 (prebuilt images pulled from GHCR)

## Installation

1. In Home Assistant, go to **Settings** → **Apps** → **App Store**
2. Click the **⋮** menu in the top right and choose **Repositories**
3. Add this URL and click **Add**:

   ```
   https://github.com/WetDogNose/home-assistant-claude
   ```

4. Find **Claude Terminal (WetDogNose)** in the store and click **Install**
5. Start the app, then click **OPEN WEB UI** or the sidebar icon
6. On first use, follow the OAuth prompts to log in to your Anthropic account

Images are pulled prebuilt from `ghcr.io/wetdognose`, so nothing is built on your Home Assistant machine.

> This fork's slug is `claude_terminal_wdn`, distinct from upstream's
> `claude_terminal`, so it installs **alongside** the original rather than
> replacing it. Each keeps its own `/data`, so each needs its own Claude login.

## Configuration

Works out of the box. All options:

| Option | Default | Description |
|--------|---------|-------------|
| `auto_launch_claude` | `true` | Start Claude on terminal open; `false` gives you a shell |
| `tmux_mouse` | `false` | tmux mouse mode; off keeps native browser selection and copy |
| `require_ingress_user` | `false` | Restrict the terminal to signed-in Home Assistant users (see security notes in [DOCS](DOCS.md#security-notes) first) |
| `claude_auto_update` | `true` | Keep Claude Code updated automatically |
| `claude_version` | `""` | Pin Claude Code (`stable`, `latest`, or `X.Y.Z`); empty tracks newest |
| `dangerously_skip_permissions` | `false` | Skip confirmation prompts, for Claude and OpenCode (see security note in [DOCS](DOCS.md#security-notes)) |
| `claude_extra_args` | `""` | Extra flags for every Claude launch |
| `enable_opencode` | `true` | OpenCode as a second agent in window 2 |
| `opencode_auto_update` | `true` | Refresh OpenCode in the background on every start |
| `opencode_version` | `""` | Pin OpenCode to an exact `X.Y.Z`; empty tracks newest |
| `opencode_lsp` | `true` | YAML checking inside OpenCode, aware of `!secret` and `!include` |
| `opencode_ha_tool_search` | `true` | Give OpenCode a search tool for Home Assistant instead of every tool at once |
| `enable_opencode_mcp` | `true` | Give Claude tools for handing work to OpenCode (third-party `opencode-mcp` package) |
| `opencode_mcp_version` | `"3.0.0"` | Exact version of that package; never updated automatically |
| `ha_smart_context` | `true` | Generate HA context file for both agents |
| `ha_context_refresh_hours` | `24` | How often to rewrite that context; `0` writes it at startup only |
| `notify_on_completion` | `true` | Notify when Claude finishes a long task or is waiting for you |
| `notify_after_seconds` | `60` | Only notify for responses that took at least this long |
| `notify_tts_target` | `""` | A `media_player` entity to speak notifications on |
| `enable_ha_entities` | `true` | Publish the add-on's state as Home Assistant entities |
| `enable_ha_mcp` | `true` | Home Assistant MCP server integration |
| `ha_mcp_version` | `"8.6.0"` | ha-mcp release to run |
| `enable_automation_api` | `true` | Enable HTTP Automation API daemon (port 8128) |
| `automation_api_port` | `8128` | Container port for Automation API server |
| `automation_api_key` | `""` | Custom API key (auto-generated in `/data/automation_api_token` if empty) |
| `git_user_name` | `""` | Author name for git commits made from the terminal |
| `git_user_email` | `""` | Author email for git commits made from the terminal |
| `persistent_apk_packages` | `[]` | APK packages to install on startup |
| `persistent_pip_packages` | `[]` | pip packages to install on startup |

See [DOCS.md](DOCS.md) for full documentation, terminal tips (scrolling, copy/paste), and troubleshooting.

## Useful Links

- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code)
- [Claude Code GitHub Repository](https://github.com/anthropics/claude-code)
- [Home Assistant Add-ons](https://www.home-assistant.io/addons/)

## Upstream & attribution

The Claude Terminal add-on is the work of
**[Tom Cassady (@heytcass)](https://github.com/heytcass)** and contributors, in
[heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons).
All credit for the original add-on belongs there.

This fork began as a change to how the add-on is built and distributed: images
are built by this repository's CI and published to `ghcr.io/wetdognose`, so
what Home Assistant runs comes from source you can inspect here. It has since
added features upstream does not have, including OpenCode, the Automation
API, notifications, entities and scheduled tasks. Both projects are MIT
licensed.

Report problems with **this fork**
[here](https://github.com/WetDogNose/home-assistant-claude/issues), not
upstream — the upstream maintainer did not build these images.

## Credits

This add-on was created with the assistance of Claude Code itself! The development process, debugging, and documentation were all completed using Claude's AI capabilities - a perfect demonstration of what this add-on can help you accomplish.

## License

MIT, as upstream. Original work © Tom Cassady and contributors — see the
[LICENSE](../LICENSE) file for details.
