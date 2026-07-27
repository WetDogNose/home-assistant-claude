# Claude Terminal

Claude Code in a web terminal, as a Home Assistant add-on.

## About

This add-on runs Anthropic's [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI in a browser-based terminal (ttyd + tmux) with your Home Assistant configuration mounted. Open it from the sidebar, log in once, and ask Claude to write automations, debug YAML, or manage your setup.

## Installation

1. In Home Assistant, go to **Settings** → **Add-ons** → **Add-on Store**
2. Click the **⋮** menu in the top right and choose **Repositories**
3. Add `https://github.com/WetDogNose/home-assistant-claude` and click **Add**
4. Find **Claude Terminal (WetDogNose)** in the store and click **Install**
5. Start the add-on, then click **OPEN WEB UI** to access the terminal
6. On first use, follow the OAuth prompts to log in to your Anthropic account

Images are pulled prebuilt from `ghcr.io/wetdognose`, so installing does not
build anything on your Home Assistant machine.

Your credentials are stored under `/data` and persist across restarts and add-on updates, so you won't need to log in again.

> **This is a fork.** It uses the slug `claude_terminal_wdn`, distinct from
> upstream's `claude_terminal`, so it installs alongside the original instead
> of replacing it. Each has its own `/data`, so each needs its own Claude
> login and keeps its own session history. See
> [Upstream & attribution](#upstream--attribution).

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `auto_launch_claude` | `true` | Start Claude immediately when the terminal opens. Set to `false` to get a shell instead (run `claude` yourself). |
| `claude_auto_update` | `true` | Keep Claude Code current: installs the official native build into `/data` and updates it in the background on each startup. |
| `dangerously_skip_permissions` | `false` | Launch Claude with `--dangerously-skip-permissions` (no confirmation prompts). **Read the security note below.** |
| `claude_extra_args` | `""` | Extra flags appended to every Claude launch, e.g. `--model claude-sonnet-5`. Values are split on spaces; quoted multi-word arguments are not supported. |
| `ha_smart_context` | `true` | Generate a CLAUDE.md with your HA system info so Claude knows your setup. |
| `enable_ha_mcp` | `true` | Register the [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) MCP server so Claude can control Home Assistant directly. |
| `ha_mcp_version` | `"7.11.0"` | ha-mcp release to run. |
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
claude-doctor   # diagnose network, auth, and environment issues
claude-login-url   # save the OAuth login URL to /config (see Troubleshooting)
github-setup    # sign in to GitHub and enable git push (see GitHub below)
persist-install apk htop   # install packages that survive restarts
ha-context      # refresh the Home Assistant context file
```

### Terminal tips

- **Scrolling**: use the mouse wheel — tmux copy-mode opens automatically. Press `q` to jump back to the bottom.
- **Copying**: select text with the mouse; on release it's copied to your clipboard (OSC 52). Long wrapped lines (like OAuth URLs) are joined back into one line automatically. Note: browsers only allow clipboard writes on secure pages — if you access Home Assistant over plain `http://`, use Shift+drag instead.
- **Shift+drag**: bypasses tmux and gives you the browser's native text selection (copy with `Ctrl+C` / right-click). Works everywhere, but wrapped lines are copied with line breaks — rejoin them by hand.
- **Pasting**: use `Ctrl+Shift+V` (or right-click, depending on browser).

### File access

The terminal starts in `/config` (your Home Assistant configuration). Also mounted:

- `/addon_configs` — configuration directories of your other add-ons
- `/share` — the shared folder

## Home Assistant MCP Integration

The bundled [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) server connects Claude to Home Assistant through the Supervisor API — no token setup needed. Claude can query states, control devices, and manage automations, scripts, and dashboards in natural language.

ha-mcp requires Python 3.13, which Alpine doesn't ship — the add-on provisions a managed Python build via [uv](https://github.com/astral-sh/uv) into `/data` on first use (a one-time ~150–250 MB download that persists across restarts and is included in HA backups). The environment is pre-warmed in the background at startup so the first MCP connection is fast.

Disable it with `enable_ha_mcp: false` if you don't want Claude to have this access.

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

- **Can't copy the OAuth login URL / "Authorization failed – Invalid request format"**: the browser terminal's clipboard path truncates very long payloads, and the login URL is one — a cut-off `state` parameter causes exactly that authorization error. Reliable path: while the login prompt is showing, open a second tmux window (`Ctrl+B` then `C`), run `claude-login-url`, and open `/config/claude-login-url.txt` with the File Editor add-on (or over Samba) — copy the URL from there. Switch back with `Ctrl+B` then `L` to paste the resulting code. Delete the file when done. Don't click the link in the terminal directly: link detection truncates URLs that wrap across lines.
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
