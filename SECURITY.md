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

If the issue is in the upstream add-on rather than this fork's build and
distribution changes, it likely also affects
[heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons)
and should be reported there too — this fork carries no code changes to the
add-on's behaviour that upstream does not have.

Third-party components have their own channels: report Claude Code issues to
[Anthropic](https://github.com/anthropics/claude-code/security), and ha-mcp
issues to [its maintainers](https://github.com/homeassistant-ai/ha-mcp).

## What this add-on is, security-wise

Understanding the intended posture makes it clearer what counts as a
vulnerability. **By design**, this add-on:

- runs as **root** inside its container;
- has **read-write** access to `/config`, `/addon_configs` and `/share`;
- holds a Supervisor token with `hassio_role: default` to query and control Home Assistant;
- with `enable_ha_mcp` on, can actuate devices and rewrite automations;
- runs an HTTP Automation API daemon (port 8128) for non-interactive automation triggers;
- executes an LLM agent that runs arbitrary shell commands.

None of the above is a vulnerability on its own — it is what a coding agent
with Home Assistant access requires in order to be useful.

### Known, accepted risks & mitigations

| Feature / Risk | Security Controls & Status |
|---|---|
| `dangerously_skip_permissions` removes the confirmation step before Claude changes files or actuates devices | Off by default; a warning is printed in the add-on log whenever it is on |
| Automation API (Port 8128) | Mandatory API Token (`X-API-Key`), IP subnet filtering (Docker container bridge only), rate-limiting (10 req/min), single process mutex, safe parameterized array execution (`shell=False`), and no host port published |
| Prompt injection via any file, issue or web page Claude reads | Inherent to agents; the confirmation step is the mitigation, which is why the option above defaults off |
| `panel_admin` controls sidebar visibility only, **not** access — any authenticated Home Assistant user can reach the terminal through ingress | Known limitation of ingress; set `require_ingress_user: true` if your proxy forwards remote identity headers |
| Publishing host ports exposes terminal or API on the LAN | Ports are left unpublished by default; access stays within ingress and container network |
| Credentials (Claude OAuth, GitHub token, Automation API key) | Stored under `/data` with 600 permissions; treat backups as secrets |

### What we do want to hear about

- Anything that lets a user **without** a Home Assistant account reach the
  terminal or the Supervisor API.
- Privilege escalation beyond the grants listed above.
- Credentials leaking somewhere not listed above — logs, the add-on
  configuration, published images, or over the network.
- A supply-chain problem in how images are built or published from this
  repository.

## Supported versions

Only the most recent release receives fixes. Versions follow
`<upstream base>-wdn.<n>`.
