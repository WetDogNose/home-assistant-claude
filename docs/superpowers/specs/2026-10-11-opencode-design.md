# OpenCode alongside Claude Code — design

Date: 2026-10-11
Target release: `2.5.1-wdn.20`, branched from `chore/dependency-refresh-wdn19`

## Goal

Run [OpenCode](https://opencode.ai/) in the Claude Terminal add-on next to
Claude Code, set up the same way Claude is, so a second agent that can talk to
any API endpoint (local models, proxies, other vendors) is available from the
same terminal.

Agreed with the user:

- **One add-on, one sidebar panel.** OpenCode is a second tmux window in the
  existing session. The originally requested separate sidebar item was dropped
  in favour of this.
- **OpenCode's config is a real `opencode.json`, edited by Claude Code** through
  a bundled command and skill. Only on/off and update switches are add-on
  options.
- **Interactive parity plus entities.** Binary guards, persistent self-updating
  copy, Home Assistant context, ha-mcp, health check and published entities.
- **OpenCode asks before edits and shell commands** unless
  `dangerously_skip_permissions` is on.
- **MCP in both directions.** OpenCode gets every MCP server Claude Code has,
  and Claude Code gets OpenCode as an MCP server it can delegate to.
- **Language servers configured automatically**, tuned for Home Assistant YAML.

Out of scope: OpenCode as a target for the Automation API or `claude-cron`, and
completion notifications.

## Verified before implementation

Every assumption taken from documentation was checked against OpenCode 1.18.35
in an Alpine 3.23 container. What was found:

| Assumption | Result |
|---|---|
| The npm tarball holds the binary at `package/bin/opencode` | Confirmed, both architectures. It also needs `libstdc++` and `libgcc`, now named in the Dockerfile |
| `OPENCODE_CONFIG_DIR` adds a plugin directory without replacing `~/.config/opencode` | Confirmed |
| `/etc/opencode/opencode.json` is the highest-priority layer | Confirmed: it overrides a project `opencode.json`, which overrides `OPENCODE_CONFIG`, which overrides the user file |
| A config check command exists | `opencode debug config`. Its output contains resolved secrets, so `validate` discards it |
| A separate Python language server is needed | **No.** OpenCode installs pyright itself; the `ty` entry was dropped |
| The built-in YAML server accepts `customTags` through `initialization` | **No.** See section 7; a small wrapper is needed |
| `opencode-mcp` auto-starts `opencode serve` on loopback | Confirmed; the server stops when the bridge does. Alpine 3.23 ships Node 24 |
| `opencode-mcp` installs at runtime with lifecycle scripts disabled | Confirmed on aarch64 |
| Plugin event names and shapes | `session.status` carries `busy`, `idle` and also `retry`; `busy` repeats many times per turn; subagents are separate sessions |

## Security review changes

A review of the first commit found problems that the sections below predate.
Where they disagree, this section is what shipped.

- **Project config is disabled** (`OPENCODE_DISABLE_PROJECT_CONFIG=1`). With
  it on, OpenCode ran `.opencode/plugins/*.js` from `/config` as root at
  startup, launched `mcp` commands from a `/config/opencode.json`, and let an
  agent file there grant itself `bash: allow` over the enforced layer. There is
  no project layer in the shipped design; section 3's table has three rows.
- **The enforced policy is "ask, except read-only tools"**, not only `edit`
  and `bash`, and is repeated under the built-in agents. The original left web
  fetches and all MCP tools, including Home Assistant's, unprompted.
- **`/config/.mcp.json` servers are shared only when Claude Code has approved
  them**, read from files under `$HOME` and failing closed.
- **The policy also covers `explore`** (spawnable by any agent, ships with
  `bash: allow`) and is exported as `OPENCODE_PERMISSION`, so it holds on every
  start path and when the enforced file could not be written.
- **A server disabled in Claude Code** (`disabledMcpServers`) is not shared.
- **`opencode-config test`** passes headers to curl in a header file, not a
  curl config, and validates with whole-string matching.
- **`opencode-yaml-ls`** installs the YAML server with `--ignore-scripts`, at
  a pinned version.
- **All built-in language servers and formatters are disabled** in the
  enforced layer; only the wrapped YAML server runs. The TypeScript server
  executed a planted `/config/node_modules/typescript` on a mere file read.
  Section 7's "Shell and Python" bullet no longer applies.
- **`opencode-config` hardening**: a host change drops stored credentials;
  the add-on's Home Assistant tokens cannot be named as a key; `--header` and
  `--env` reject `{env:}`/`{file:}`; `test` follows `{file:}` only inside
  `secrets/`; `--npm` is limited to `@ai-sdk/*`; endpoint- and file-supplied
  names are sanitised before printing.
- **`opencode-launch` fails closed** when neither copy of the policy exists.

## 1. Binary

Same three guards as Claude, because "installed" and "actually runs" are
separate facts for any native musl binary.

**Build time (Dockerfile).** Fetch the tarball straight from the npm registry,
no npm or Node, exactly as the Claude step does:

- aarch64: `opencode-linux-arm64-musl`
- amd64: `opencode-linux-x64-baseline-musl`. The non-baseline build requires
  AVX2, which older Celeron and Atom boxes lack; a crash on launch there would
  be the blank-terminal failure again.

Install to `/usr/local/bin/opencode`, run `ldd`, fail the build on
`symbol not found`, and add `"opencode": "<version>"` to
`/usr/local/share/claude-terminal/build-versions.json`. An `OPENCODE_VERSION`
build arg pins it; empty means the registry's `latest` tag (the 1.x line).

**Boot time (`update_opencode` in `run.sh`).** Backgrounded, never on the boot
path. When `opencode_auto_update` is on:

1. Resolve the wanted version: `opencode_version` if set, else registry `latest`.
2. Skip if `/data/home/.local/bin/opencode --version` already reports it.
3. Download to a temp file in `/tmp`, probe it with `timeout 10 … --version`,
   and only then `mv` it into `/data/home/.local/bin/opencode`.

Independently of the option, an existing persistent copy that fails the probe is
deleted at boot, as with Claude.

OpenCode's own updater is disabled (`OPENCODE_DISABLE_AUTOUPDATE=1` and
`"autoupdate": false` in the enforced layer), so the probed path above is the
only way the binary changes.

**Launch time (`scripts/opencode-launch.sh`).** Plain bash, no bashio. Probes
the persistent copy, then the bundled one, runs the first that works as a child
process, and on exit prints the status and drops to `welcome --shell`. If
neither runs it explains why and drops to the shell. On every exit path it
resets the OpenCode entity state to idle (section 5).

## 2. Terminal

`scripts/terminal-session.sh` replaces the inline `tmux new-session -A …`
string that `get_claude_launch_command` returns today.

- Session absent: create it detached with window 1 `claude` running the current
  command (`claude-launch <flags>` or `welcome --shell`), then, when
  `enable_opencode` is on, window 2 `opencode` running `opencode-launch`. Then
  attach to window 1.
- Session present: attach. Nothing is recreated.

Window 2 shows a short banner and starts OpenCode when Enter is pressed, so an
unused OpenCode costs no memory.

Switching: `Ctrl-b 1` / `Ctrl-b 2`, clicking the window name in the status bar,
or a new "Switch to OpenCode / Claude" entry in the existing `Ctrl-b h` menu.
The welcome banner mentions the second window.

`run.sh` passes the Claude flags and the enable switch to the wrapper as
arguments and environment; the wrapper itself reads no options, since bashio is
not available under ttyd.

## 3. Configuration

Three layers, so the add-on never rewrites a file the user and Claude own. This
is the same rule as `claude-hooks` and `settings.json`, solved by layering
instead of by editing in place, because OpenCode merges config files natively.
Its precedence, lowest to highest, is: global file, `OPENCODE_CONFIG` file,
project `opencode.json`, then the managed directory `/etc/opencode/`.

| Layer | Path | Written by | Wins over |
|---|---|---|---|
| Defaults | `/run/claude-terminal/opencode-defaults.json` (`OPENCODE_CONFIG`) | add-on, every boot | the user layer, for keys both set |
| User | `/data/.config/opencode/opencode.json` | Claude Code and the user | nothing |
| Project | `/config/opencode.json`, optional | the user | defaults and user |
| Enforced | `/etc/opencode/opencode.json` | add-on, every boot | everything |

Both add-on layers live outside `/data`, so neither can outlive the release
that wrote it.

**User layer.** OpenCode's normal global path, since `XDG_CONFIG_HOME` is
already `/data/.config`. Persists, is backed up, and holds everything about
providers: `provider.<id>.options.baseURL`, `apiKey`, `headers`, `npm`
(`@ai-sdk/openai-compatible` or `@ai-sdk/openai`), `models`, and the default
`model`. Created on first use, never at boot.

**Enforced layer.** Only what must not be overridable:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "permission": { "edit": "ask", "bash": "ask" }
}
```

`permission` is omitted when `dangerously_skip_permissions` is true, which
leaves OpenCode at its allow-by-default behaviour. The option is read with the
same fail-safe pattern as `build_claude_flags`: an unreadable option means
"ask". This layer exists because the terminal's working directory is `/config`,
and a project `opencode.json` there outranks the defaults layer; without it an
agent could loosen its own prompts by writing one file.

**Defaults layer.** Things the add-on provides but the user may override from a
project config:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "instructions": ["/data/home/.claude/CLAUDE.md"],
  "lsp": { "…": "section 7" },
  "mcp": {
    "home-assistant": {
      "type": "local",
      "command": ["uvx", "--python", "3.13", "--index-strategy",
                  "unsafe-best-match", "ha-mcp@<ha_mcp_version>"],
      "environment": {
        "HOMEASSISTANT_URL": "http://supervisor/core",
        "HOMEASSISTANT_TOKEN": "{env:SUPERVISOR_TOKEN}"
      },
      "enabled": true
    },
    "…": "servers shared from Claude Code, section 6"
  }
}
```

- `mcp.home-assistant` is omitted when `enable_ha_mcp` is false.
- `instructions` is omitted when `ha_smart_context` is false.
- The Supervisor token is referenced, never written into the file.
- The file is mode 600: servers shared from Claude Code can carry credentials.

Both files are written by `opencode-layers` (`scripts/opencode-layers.sh`,
plain bash and `jq`). `run.sh` calls it at boot with the option values as
arguments; `opencode-config mcp sync` calls it again with the values recorded
at boot. One generator, so the boot-time file and a later resync cannot
disagree.

`OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1` is exported so the context file is
loaded once through `instructions` rather than a second time through
OpenCode's Claude-compatibility fallback. Skill compatibility stays on, so the
bundled Home Assistant skills in `~/.claude/skills` are available in OpenCode.

**Secrets.** API keys go in `/data/.config/opencode/secrets/<provider>` (mode
600, directory 700) and are referenced from the user layer as
`{file:/data/.config/opencode/secrets/<provider>}`. They are not excluded from
backups: like `.config/claude`, they are irreplaceable user state.

## 4. Control from Claude Code

**`scripts/opencode-config.sh`**, installed as `opencode-config`. Plain bash
and `jq`.

| Subcommand | Does |
|---|---|
| `path` | Print the user-layer path |
| `show` | Print the user layer with inline keys and header values redacted |
| `set-provider <id> --base-url <url> [--npm <pkg>] [--name <n>] [--model <id> …] [--header K=V …] [--api-key-stdin]` | Create or update one provider. A key read from stdin is written to the secrets file and referenced by `{file:}` |
| `set-model <provider/model>` | Set the default model |
| `remove-provider <id>` | Remove the provider and its secrets file |
| `mcp list` | Show OpenCode's MCP servers and which layer each comes from |
| `mcp add <name> (--url <url> \| -- <command…>) [--env K=V …] [--header K=V …]` | Add an OpenCode-only server to the user layer |
| `mcp remove <name>` | Remove one from the user layer |
| `mcp sync` | Regenerate the defaults layer from Claude Code's current MCP servers (section 6) |
| `validate` | Parse the JSON, check each `{file:}` reference exists, then run OpenCode's own config check |
| `test <id>` | `GET <baseURL>/models` with the provider's key and headers; report status and model count |

Rules it follows:

- Writes are atomic (`mktemp` then `mv`) and keep one `opencode.json.bak`.
- It refuses to modify a file it cannot parse and says so. It never replaces
  one with a fresh default.
- No boolean default uses `jq`'s `//`.
- A key is never accepted as a command-line argument, only on stdin, so it does
  not land in shell history or `ps`.
- Changes need an OpenCode restart; the command says so.

**`skills/opencode-config/SKILL.md`.** Tells Claude when to use the command,
gives recipes (OpenAI-compatible endpoint, Ollama, LM Studio, OpenRouter, Azure
OpenAI, an Anthropic-compatible proxy via `baseURL`, a Responses-API endpoint
via `@ai-sdk/openai`), and states that for anything the command does not cover,
Claude edits the JSON directly and then runs `opencode-config validate`. That
direct-edit path is what makes any endpoint OpenCode supports reachable, rather
than only those the subcommands anticipate. The skill also explains the layers, so
Claude does not try to set permissions in the user file and wonder why they do
not stick, and covers `mcp sync` and delegating to OpenCode through the bridge.

## 5. Entities

**`ha-entity` gains `--agent opencode`.** The agent selects a state file
(`/data/opencode-state.json`), an entity prefix and friendly-name prefix. With
no flag the behaviour is unchanged, so every existing caller keeps working.
`heartbeat` republishes both agents; OpenCode's only when its state file
exists, which `run.sh` seeds when `enable_opencode` and `enable_ha_entities`
are both on.

| Entity | State |
|---|---|
| `binary_sensor.opencode_busy` | on while a session is working |
| `sensor.opencode_status` | `idle`, `running`, `retrying`, `waiting` (a permission prompt is open), `error`; attributes: `model`, `addon_version` |
| `sensor.opencode_last_run` | timestamp of the last completed turn; `unknown` until there is one |
| `sensor.opencode_last_result` | `ok` or `error`; attribute `error` |
| `sensor.opencode_version` | OpenCode version in use |

There is no `login_required` equivalent: OpenCode has no single sign-in.

**`opencode/plugins/ha-entities.js`** (copied to `/opt/opencode/plugins/`,
found through `OPENCODE_CONFIG_DIR=/opt/opencode`). No imports, so OpenCode has
nothing to install and startup needs no network. Event mapping:

| Event | State written |
|---|---|
| `session.status` busy | `busy=true status=running` (published once per change, not per event) |
| `session.status` retry | `busy=true status=retrying last_error=<message>` |
| `permission.asked` | `status=waiting` |
| `permission.replied` | `status=running` |
| `session.idle` | `busy=false status=idle last_result=ok last_run=<now>`, only once no session is still busy and the turn did not error |
| `session.error` | `busy=false status=error last_result=error last_error=<message> last_run=<now>` |

The plugin spawns `ha-entity` without awaiting it and swallows every failure:
reporting must not be able to slow or break the thing it reports on. It does
nothing when `ha-entity` is absent or entities are disabled.

`opencode-launch` writes `busy=false status=idle` after OpenCode exits for any
reason, so a crash mid-turn cannot leave the busy sensor on.

## 6. MCP, both directions

### OpenCode uses Claude Code's servers

`opencode-layers` reads Claude Code's MCP servers and translates them into the
defaults layer, so a server added with `claude mcp add` appears in OpenCode
without being configured twice.

Sources, later ones winning on a name clash:

1. `$HOME/.claude.json` → `.mcpServers` (user scope)
2. `$HOME/.claude.json` → `.projects["/config"].mcpServers` (local scope)
3. `/config/.mcp.json` → `.mcpServers` (project scope)

Translation:

| Claude Code | OpenCode |
|---|---|
| `command` + `args` | `"type": "local"`, `"command": [command, …args]` |
| `env` | `environment` |
| `"type": "http"` or `"sse"` with `url`, `headers` | `"type": "remote"`, `url`, `headers` |

Rules:

- The entry named `opencode` is never copied. It is the bridge below, and
  copying it would have OpenCode calling itself.
- `home-assistant` is never copied; the add-on's own entry is used, which
  references the token instead of embedding the copy `claude mcp add` wrote.
- An entry that does not translate (unknown transport, missing command) is
  skipped with a line on stderr, not guessed at.
- An unparseable source file is skipped whole, with a warning. It does not stop
  the layer being written.

It runs at boot and on `opencode-config mcp sync`. Like any OpenCode config
change, a running OpenCode picks it up on restart; the skill tells Claude to
run `mcp sync` after `claude mcp add` and say so.

OpenCode-only servers go in the user layer through `opencode-config mcp add`.

### Claude Code can drive OpenCode

OpenCode has no MCP server mode of its own. The bridge is
[`opencode-mcp`](https://github.com/AlaeddineMessadi/opencode-mcp), a
third-party package (one maintainer, MIT, not affiliated with OpenCode) that
talks to `opencode serve` over HTTP. It lets Claude send a prompt to OpenCode,
on whatever endpoint OpenCode is configured for, and read the result.

- **Install.** In `provision_async`, never on the boot path:
  `npm install --prefix /data/.local/share/opencode-mcp opencode-mcp@<version>`,
  skipped when that version is already present. The directory is added to
  `backup_exclude`.
- **Version.** Exact, from a new `opencode_mcp_version` option (default
  `3.0.0`), the same way `ha_mcp_version` pins ha-mcp. It runs as root beside
  the Supervisor token, so it is never fetched as `latest` and never through
  `npx` at session start. Its own dependencies use caret ranges and are not
  locked by this pin; that residual risk is stated in `DOCS.md`.
- **Register.** `claude mcp remove opencode; claude mcp add opencode …` with
  the command `node <prefix>/node_modules/opencode-mcp/dist/index.js` and env
  `OPENCODE_AUTO_SERVE=true`, `OPENCODE_BASE_URL=http://127.0.0.1:4096`,
  `OPENCODE_TOOL_PROFILE=essential`. Re-registered every boot, like ha-mcp, so
  it is shipped state.
- **Server.** Started on demand by the bridge, bound to loopback inside the
  container. No port is published and nothing listens until Claude first uses
  an OpenCode tool, so the feature costs no memory when unused.
- **Tool profile.** `essential`, because the full profile adds about 70 tool
  definitions to every Claude session.
- **Switch.** `enable_opencode_mcp` (default true). Off removes the
  registration and skips the install.

Consequences worth knowing:

- A delegated OpenCode run that hits a permission prompt waits for an answer,
  and the bridge lets Claude supply it. With permissions at "ask", Claude is
  therefore the one approving OpenCode's edits, after the user has approved
  Claude's call to the OpenCode tool. `DOCS.md` says this plainly.
- The entity plugin loads in the served instance too, so
  `binary_sensor.opencode_busy` covers delegated runs as well as interactive
  ones.

## 7. Language servers

OpenCode starts no language server unless the config has an `lsp` key, so the
defaults layer supplies one when `opencode_lsp` is on:

```json
"lsp": {
  "yaml-ls": {
    "command": ["opencode-yaml-ls"],
    "extensions": [".yaml", ".yml"],
    "initialization": { "yaml": { "keyOrdering": false, "customTags": [
      "!include scalar", "!include_dir_list scalar", "!include_dir_named scalar",
      "!include_dir_merge_list scalar", "!include_dir_merge_named scalar",
      "!secret scalar", "!env_var scalar", "!input scalar",
      "!lambda scalar", "!extend scalar", "!remove scalar"
    ] } }
  }
}
```

- **YAML.** Without Home Assistant's tags declared, every `!secret` and
  `!include` line is reported as an error, which is worse than no language
  server. Overriding a built-in entry requires a `command`, and passing the
  tags through the built-in server does not work: OpenCode sends the settings
  correctly, but yaml-language-server's `initialized` handler throws while
  registering for workspace-folder changes (OpenCode names a folder without
  declaring that client capability) before it registers its settings
  listeners. `scripts/opencode-yaml-ls.js` is a stdio pass-through that adds
  that one capability to the `initialize` request. It reuses the server copy
  OpenCode downloads, installing it to the same cache path if absent.
- **Shell and Python.** OpenCode's built-in bash server and pyright are on by
  virtue of the `lsp` key and install themselves; they need no entry.

OpenCode downloads language servers the first time a matching file is opened.
That happens inside OpenCode, not on the boot path, and lands in
`.cache/opencode`, which is excluded from backups. Offline, the download fails
and OpenCode carries on without that server.

The option exists because each language server is another long-lived process,
which matters on a Pi.

## 8. Health check

`claude-doctor` reports: which OpenCode copy runs and its version; whether the
user layer parses; whether both add-on layers exist; how many MCP servers were
shared from Claude Code and how many were skipped; whether the bridge is
installed at the pinned version and registered with Claude.

## 9. Options

| Option | Default | Read by |
|---|---|---|
| `enable_opencode` | `true` | `update_opencode`, `opencode-layers`, `start_web_terminal`, `start_entity_heartbeat` |
| `opencode_auto_update` | `true` | `update_opencode` |
| `opencode_version` | `""` | `update_opencode` |
| `opencode_lsp` | `true` | `opencode-layers` |
| `enable_opencode_mcp` | `true` | `setup_opencode_mcp` (in `provision_async`) |
| `opencode_mcp_version` | `"3.0.0"` | `setup_opencode_mcp` |

All read through `config_or`. `dangerously_skip_permissions`, `enable_ha_mcp`,
`ha_mcp_version`, `ha_smart_context` and `enable_ha_entities` gain OpenCode as
a consumer.

`backup_exclude` gains `home/.local/bin/opencode`, `.cache/opencode`,
`.local/share/opencode/log` and `.local/share/opencode-mcp` (`.cache/opencode`,
where language servers land, is covered by the first). Sessions and
`auth.json` under `.local/share/opencode` stay in backups.

## 10. Failure behaviour

- OpenCode missing or broken: window 2 explains and gives a shell. Window 1 and
  Claude are unaffected. Nothing OpenCode-related can stop `run.sh` reaching
  `exec ttyd`; every new step captures its own failure.
- User config unparseable: OpenCode reports it in window 2;
  `opencode-config` refuses to edit and names the backup.
- Defaults layer cannot be written: `OPENCODE_CONFIG` is left unset and a
  warning is logged. OpenCode still starts, without ha-mcp, shared servers or
  language servers.
- Enforced layer cannot be written: logged as an error, because OpenCode then
  runs with its own allow-by-default permissions. OpenCode is still started;
  the banner in window 2 repeats the warning.
- Bridge install or registration fails: reported through the existing
  provisioning notice. Claude and OpenCode both work; Claude has no OpenCode
  tools.
- Update download fails or the new build does not run: the existing copy stays.

## 11. Files

New:

- `claude-terminal/scripts/terminal-session.sh`
- `claude-terminal/scripts/opencode-launch.sh`
- `claude-terminal/scripts/opencode-config.sh`
- `claude-terminal/scripts/opencode-layers.sh`
- `claude-terminal/scripts/opencode-yaml-ls.js`
- `claude-terminal/scripts/setup-opencode-mcp.sh` (sourced by `run.sh`, like
  `setup-ha-mcp.sh`)
- `claude-terminal/opencode/plugins/ha-entities.js`
- `claude-terminal/skills/opencode-config/SKILL.md`

Changed:

- `Dockerfile` — fetch and check the binary; `COPY opencode/ /opt/opencode/`
- `run.sh` — `update_opencode`, the `opencode-layers` call, exports,
  `setup_commands`, `provision_async`, `start_web_terminal`,
  `start_entity_heartbeat`
- `scripts/ha-entity.sh` — `--agent`
- `scripts/health-check.sh` — section 8
- `scripts/tmux.conf`, `scripts/welcome.sh` — menu entry and banner line
- `config.yaml` — options, schema, `backup_exclude`, version
- `translations/` — option labels
- `DOCS.md`, `CHANGELOG.md`, `README.md`, root `CLAUDE.md`
- `ci/smoke.sh` — new scripts, binary, skill, plugin
- `tests/test_scripts.sh`

## 12. Testing

Unit (`tests/test_scripts.sh`, run against temp directories):

- `opencode-config`: `set-provider` output shape; key from stdin lands in a
  600 file and only a `{file:}` reference lands in the JSON; `show` redacts;
  unparseable file is refused and left byte-identical; `remove-provider`
  deletes the secret; backup is written; a provider flag set to `false`
  survives a round trip.
- `ha-entity --agent opencode`: uses its own state file and entity names; the
  no-flag path still produces the six Claude entities unchanged.
- `opencode-layers`, enforced: `permission` present by default, absent with
  `dangerously_skip_permissions`, present when the option is unreadable.
- `opencode-layers`, defaults: `mcp.home-assistant`, `instructions` and `lsp`
  follow their options; the Supervisor token never appears in the file; the
  file is mode 600.
- MCP sharing: stdio and remote servers translate as in section 6; the three
  sources merge in the stated order; `opencode` and `home-assistant` are never
  copied; an untranslatable entry is skipped and the rest still land; an
  unparseable `.claude.json` still produces a valid layer.
- `opencode-config mcp add` / `remove` touch only the user layer.
- `terminal-session`: creates two windows when enabled, one when disabled, and
  creates nothing on reattach.
- Existing rule extended: a skill must not name a command `setup_commands`
  does not install.

Image (`ci/smoke.sh`): `/usr/local/bin/opencode --version` succeeds on amd64,
new scripts are executable, the skill has valid frontmatter, the plugin file
exists.

Boot (`ci/boot-test.sh`): the add-on still reaches a listening ttyd with
`enable_opencode` both on and off.

Manual, in a local container: open window 2, start OpenCode, point it at a
local OpenAI-compatible endpoint with `opencode-config set-provider`, run
`test`, and send one prompt. Open a Home Assistant YAML file containing
`!secret` and confirm no diagnostics are raised for it. Add a server with
`claude mcp add`, run `opencode-config mcp sync`, and confirm OpenCode lists
it. From Claude, ask OpenCode a question through the bridge and confirm the
busy sensor turns on and off.
