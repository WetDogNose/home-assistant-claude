# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting instead:
**[Report a vulnerability](https://github.com/WetDogNose/home-assistant-claude/security/advisories/new)**
(Security → Advisories → Report a vulnerability). If that is unavailable, open
an issue containing only "security report, please contact me" with no detail,
and we will arrange a private channel.

Please include the add-on version (from the add-on page), your Home Assistant
and Supervisor versions, your architecture, and what an attacker would gain.

This fork has diverged from upstream: OpenCode, the Automation API,
notifications, entities, scheduled tasks and most of the helper commands
exist only here, so report problems in those to this repository. If the issue
is in something the upstream add-on also has (the terminal itself, Claude
Code's install and sign-in, ha-mcp registration), it likely also affects
[heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons)
and should be reported there too.

Third-party components have their own channels: report Claude Code issues to
[Anthropic](https://github.com/anthropics/claude-code/security), ha-mcp
issues to [its maintainers](https://github.com/homeassistant-ai/ha-mcp),
OpenCode issues to [its project](https://opencode.ai/), and issues
in the bridge package to
[opencode-mcp](https://github.com/AlaeddineMessadi/opencode-mcp). A problem
in how this add-on configures, pins or constrains any of them belongs here.

## What this add-on is, security-wise

Understanding the intended posture makes it clearer what counts as a
vulnerability. **By design**, this add-on:

- runs as **root** inside its container;
- has **read-write** access to `/config`, `/addon_configs` and `/share`;
- holds a Supervisor token with `hassio_role: default` to query and control Home Assistant;
- with `enable_ha_mcp` on, can actuate devices and rewrite automations;
- runs an HTTP Automation API daemon (port 8128) for non-interactive automation triggers;
- executes an LLM agent that runs arbitrary shell commands;
- with `enable_opencode` on, runs a second agent, OpenCode, with the same
  access, talking to whatever API endpoint the user configured for it;
- with `enable_opencode_mcp` on, lets Claude start OpenCode in the background
  and answer its permission prompts.

None of the above is a vulnerability on its own — it is what a coding agent
with Home Assistant access requires in order to be useful.

### Known, accepted risks & mitigations

| Feature / Risk | Security Controls & Status |
|---|---|
| `dangerously_skip_permissions` removes the confirmation step before Claude changes files or actuates devices | Off by default; a warning is printed in the add-on log whenever it is on |
| Automation API (Port 8128) | Mandatory API Token (`X-API-Key`), IP subnet filtering (Docker container bridge only), rate-limiting (10 req/min), single process mutex, safe parameterized array execution (`shell=False`), and no host port published |
| OpenCode's own defaults allow every tool, and it executes plugins, MCP commands, agents and language servers found in the working directory | The add-on writes an enforced config layer (`/etc/opencode/opencode.json`) that outranks the user's: ask before anything except read-only tools, repeated per built-in agent. The same policy is exported as `OPENCODE_PERMISSION`, and OpenCode is not started without one of the two. Project config from `/config` is disabled, and every built-in language server and formatter is switched off |
| MCP servers shared from Claude into OpenCode | A server from `/config/.mcp.json` is shared only once approved in Claude Code, with the approval read from `$HOME`, never from the project. Entries carrying `{env:}` / `{file:}` references are refused |
| OpenCode API keys | Accepted on stdin only, stored one per file (600) under `/data/.config/opencode/secrets/`. Giving a provider a new address without a key replaces the old key with a placeholder, so a stored credential is not sent to a new host |
| `opencode-mcp` bridge is third-party code running as root | Exact version pin (`opencode_mcp_version`), installed with `--ignore-scripts`, run as `node <path>` and never through `npx`. Its transitive dependencies are **not** pinned. `opencode serve` listens on loopback only. Disable with `enable_opencode_mcp: false` |
| A task Claude delegates to OpenCode has its permission prompts answered by Claude, not the user | Accepted: the user approves the delegation itself. The enforced policy still applies to the delegated run |
| Prompt injection via any file, issue or web page Claude reads | Inherent to agents; the confirmation step is the mitigation, which is why the option above defaults off |
| `panel_admin` controls sidebar visibility only, **not** access — any authenticated Home Assistant user can reach the terminal through ingress | Known limitation of ingress; set `require_ingress_user: true` if your proxy forwards remote identity headers |
| Publishing host ports exposes terminal or API on the LAN | Ports are left unpublished by default; access stays within ingress and container network |
| Credentials (Claude OAuth, GitHub token, Automation API key, OpenCode provider keys and sign-ins) | Stored under `/data` with 600 permissions; treat backups as secrets |

### What we do want to hear about

- Anything that lets a user **without** a Home Assistant account reach the
  terminal or the Supervisor API.
- Privilege escalation beyond the grants listed above.
- Credentials leaking somewhere not listed above — logs, the add-on
  configuration, published images, or over the network.
- A supply-chain problem in how images are built or published from this
  repository.
- Any way for OpenCode to edit, run or actuate something without a prompt
  while `dangerously_skip_permissions` is off, or for a file in `/config` to
  be executed or to change OpenCode's configuration.
- Any way to make `opencode-config` send a stored credential or a Home
  Assistant token to a host the user did not choose.

## Supported versions

Only the most recent release receives fixes. Versions follow
`<upstream base>-wdn.<n>`.
