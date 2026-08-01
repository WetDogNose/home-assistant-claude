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
| `enable_ha_mcp` | `true` | Register the [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) MCP server so Claude can control Home Assistant directly. |
| `ha_mcp_version` | `"7.11.0"` | ha-mcp release to run. |
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
ha-validate     # validate HA configuration via API (use --safe-edit <file> for backup safety)
ha-dashboard    # generate Lovelace YAML dashboard by domain or area (<domain_or_area>)
ha-mesh         # scan Zigbee, Z-Wave & Matter mesh network health and low batteries
ha-memory       # search HA historical event and state transitions (<entity_id> [hours])
ha-snapshot     # capture camera image for Claude vision inspection (<camera_entity>)
ha-scaffold     # generate boilerplate for custom integration (<domain>) or PyScript (pyscript <name>)
ha-git-backups  # git config time-machine backup and 1-click rollback (commit|rollback)
ha-assist       # query HA Assist voice conversation pipeline (<prompt>)
claude-bot      # remote messaging gateway for Telegram, Matrix, Discord (forward <prompt>)
claude-cron     # manage autonomous background scheduled prompts (add|list|remove)
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

### Terminal tips

- **Automatic Login Notifications**: When Claude Code displays an OAuth authorization link, a Home Assistant persistent notification is automatically sent to the notification drawer with a direct clickable link (`[👉 Authorize Claude Code]`).
- **Copying & URL Clicking**: With default settings (`tmux_mouse: false`), native browser selection works directly — select text with your mouse and copy with `Ctrl+C` / `Cmd+C` or right-click. Terminal URLs (`https://...`) can be clicked directly to open in a new tab.
- **Tmux Mouse Mode**: If `tmux_mouse: true` is enabled, `Shift+drag` bypasses tmux mouse mode to perform native browser selection, and `Shift+Click` opens URLs.
- **Pasting**: Use `Ctrl+Shift+V` (or `Cmd+V` / right-click, depending on browser).

### File access

The terminal starts in `/config` (your Home Assistant configuration). Also mounted:

- `/addon_configs` — configuration directories of your other add-ons
- `/share` — the shared folder

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
- **Process Mutex & Rate Limiting**: Prompts are executed sequentially (max 1 active process) with a 10 requests/minute rate limit per IP.
- **Command Injection Safety**: Prompts are passed directly via array arguments to `subprocess.run(..., shell=False)`.

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

**`dangerously_skip_permissions` removes the last human checkpoint.** With it enabled, a misunderstanding — or a prompt injection in any file or web page Claude reads — can modify your HA configuration or actuate devices without asking you first. Leave it off unless you understand and accept that trade-off. A warning banner is printed in the add-on log whenever it is active.

## Troubleshooting

- **Can't copy the OAuth login URL**: run `claude-login-url` — as well as writing the URL to `/config`, it now pushes it to your Home Assistant **notifications**, where you can select and copy it with the browser's own clipboard. Full detail: the browser terminal's clipboard path truncates very long payloads, and the login URL is one — a cut-off `state` parameter causes exactly that authorization error. Reliable path: while the login prompt is showing, open a second tmux window (`Ctrl+B` then `C`), run `claude-login-url`, and open `/config/claude-login-url.txt` with the File Editor add-on (or over Samba) — copy the URL from there. Switch back with `Ctrl+B` then `L` to paste the resulting code. Delete the file when done. Don't click the link in the terminal directly: link detection truncates URLs that wrap across lines.
- **"Press Enter to Reconnect", or the panel loads but never connects**: you have `require_ingress_user: true` and your installation does not attach the user identity to the ingress WebSocket. Set it back to `false` and restart. This is why the option defaults to off.
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
