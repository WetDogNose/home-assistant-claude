<div align="center">

<img src="claude-terminal/logo.png" alt="Claude Terminal" width="260">

### Claude Code in a browser terminal, inside Home Assistant

Write automations, debug YAML and control your instance in plain language —
without leaving the Home Assistant sidebar.

![Version](https://img.shields.io/badge/version-2.5.1--wdn.1-d97757?style=for-the-badge)
![Architectures](https://img.shields.io/badge/arch-amd64%20%7C%20aarch64-2b5b84?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-4c9a5a?style=for-the-badge)
![Ingress](https://img.shields.io/badge/ingress-enabled-1a1b26?style=for-the-badge)

</div>

---

<div align="center">
  <img src="claude-terminal/screenshot.png" alt="Claude Terminal running in Home Assistant" width="760">
</div>

---

## What you get

|  | Feature |
|:--:|---|
| 🖥️ | **Just Claude Code** — opens straight into Claude, no menus in the way |
| 🏠 | **Knows your setup** — version, entities and add-ons are summarised for Claude automatically |
| 🔌 | **Controls Home Assistant** — bundled [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) server for natural-language device and automation control |
| 🔁 | **Survives reloads** — tmux keeps your conversation alive across browser refreshes and navigation |
| 🔑 | **Log in once** — OAuth credentials persist across restarts and updates |
| 🐙 | **GitHub built in** — the `gh` CLI ships in the image; run `github-setup` and Claude can manage repos and push commits |
| 📦 | **Persistent packages** — `persist-install` keeps extra apk/pip tools across restarts |
| 📁 | **Broad file access** — `/config`, `/addon_configs` and `/share` are mounted |

---

## Install

> [!IMPORTANT]
> This repository is **private**, and the Supervisor clones add-on repositories
> anonymously. It therefore needs a GitHub token embedded in the repository URL.

<details>
<summary><b>Step 1 — create a read-only access token</b></summary>

<br>

On GitHub: **Settings** → **Developer settings** → **Personal access tokens** →
**Fine-grained tokens** → **Generate new token**

| Setting | Value |
|---|---|
| Repository access | *Only select repositories* → `home-assistant-claude` |
| Permissions | *Repository permissions* → **Contents: Read-only** |
| Expiry | Whatever you are willing to renew |

Read-only access to Contents is all a clone needs. Prefer a fine-grained token
over a classic one — a classic token's `repo` scope grants read **and write** to
*every* private repository you own, where this grants read to exactly one.

</details>

**Step 2 — add the repository**

1. Go to **Settings** → **Add-ons** → **Add-on Store**
2. Click **⋮** (top right) → **Repositories**
3. Add this URL, with your token substituted:

   ```text
   https://WetDogNose:YOUR_TOKEN@github.com/WetDogNose/home-assistant-claude.git
   ```

4. Install **Claude Terminal (WetDogNose)**, then start it
5. Click **OPEN WEB UI**, and follow the OAuth prompts on first launch

Images are pulled prebuilt from `ghcr.io/wetdognose`, so nothing is compiled on
your Home Assistant machine.

> [!WARNING]
> The Supervisor stores that URL **verbatim** — the token appears in the
> repository list and in every Home Assistant backup, which is exactly why it
> should be read-only and scoped to this one repository. Expiry is silent: the
> store simply stops seeing new versions, so update the URL with a fresh token.

> [!NOTE]
> **Installs alongside the original.** This fork's slug is `claude_terminal_wdn`,
> distinct from upstream's `claude_terminal`, so both can coexist. Each keeps its
> own `/data` — separate Claude login, separate history.

---

## Configuration

Works out of the box. Every option is labelled in the Home Assistant UI; the
full reference lives in **[DOCS.md](claude-terminal/DOCS.md)**.

| Option | Default | What it does |
|---|:--:|---|
| `auto_launch_claude` | `true` | Start Claude on open, or drop to a shell |
| `claude_auto_update` | `true` | Keep Claude Code current in the background |
| `claude_version` | `""` | Pin to `stable`, `latest` or `X.Y.Z` |
| `dangerously_skip_permissions` | `false` | ⚠️ Removes the confirmation step |
| `claude_extra_args` | `""` | Extra flags for every launch |
| `ha_smart_context` | `true` | Summarise your HA setup for Claude |
| `enable_ha_mcp` | `true` | Let Claude control Home Assistant |
| `ha_mcp_version` | `7.11.0` | Which ha-mcp release backs that connection |
| `git_user_name` / `git_user_email` | `""` | Commit identity for git |
| `persistent_apk_packages` | `[]` | apk packages reinstalled each boot |
| `persistent_pip_packages` | `[]` | pip packages reinstalled each boot |

---

## Security

> [!CAUTION]
> **This add-on is powerful by design.** It runs as root, has read-write access
> to `/config`, `/addon_configs` and `/share`, and with MCP enabled can control
> devices and rewrite automations.

`dangerously_skip_permissions` removes the last human checkpoint. With it on, a
misunderstanding — or a prompt injection hidden in any file, issue or web page
Claude reads — can change your configuration or actuate devices without asking.
Leave it off unless you accept that trade-off.

Full notes, including where credentials are stored and what lands in backups,
are in **[DOCS.md](claude-terminal/DOCS.md#security-notes)**.

---

## Releasing

Merging to `main` ships **nothing**. Publishing is driven entirely by pushing a
`v*` tag, so a release is: bump the version, write the changelog, tag.

### 0. One-time: point `gh` at this repository

This repo has an `upstream` remote, and the GitHub CLI resolves a bare command
to the **parent** repository when it finds one. So `gh run list` reports on
upstream's runs, not yours — quietly, with plausible-looking output.

Fix it once:

```bash
gh repo set-default WetDogNose/home-assistant-claude
```

Otherwise pass `-R WetDogNose/home-assistant-claude` to every `gh` command
below. Note it is needed on **each** command in a pipeline, including any
nested `$(gh ...)` that supplies an argument.

### 1. Choose the version number

Versions are `<upstream base>-wdn.<n>`:

| Situation | Next version |
|---|---|
| Your own change, same upstream base | bump `n` → `2.5.1-wdn.2` |
| You merged a new upstream release | take their version, reset `n` → `2.6.0-wdn.1` |

Check what the current one is, and what has already shipped:

```bash
grep '^version:' claude-terminal/config.yaml
git tag -l 'v*' | sort -V | tail -5
```

`n` only ever goes up within a base. Never reuse a tag — the image tag is
derived from this version, and a reused tag silently changes what an already
published version means.

### 2. Bump and describe it

Both are required, and `release.yml` fails the tag if they disagree:

```bash
# claude-terminal/config.yaml
version: "2.5.1-wdn.2"

# claude-terminal/CHANGELOG.md — a section whose heading matches EXACTLY
## 2.5.1-wdn.2
```

The changelog section becomes the GitHub release notes, so write it for
someone deciding whether to update, not for yourself.

Open a PR with those two changes as normal — `main` is protected, and the
required checks must pass.

> [!NOTE]
> **Not every merge needs a release.** The Supervisor reads `config.yaml`,
> `DOCS.md` and `translations/` from the default branch, so changes to those
> take effect on merge — a store reload is enough. Only changes that land
> *inside the image* need a new version and tag:
>
> ```bash
> git diff --name-only $(git describe --tags --abbrev=0)..main -- \
>   claude-terminal/Dockerfile claude-terminal/run.sh claude-terminal/scripts/
> ```
>
> Non-empty means tag. Empty means reload the store and you are done.

### 3. Tag it

Once that PR is merged:

```bash
git checkout main && git pull
git tag v2.5.1-wdn.2 && git push origin v2.5.1-wdn.2
```

That single push runs the whole release: `release.yml` verifies the tag matches
`config.yaml`, extracts your changelog section and creates the GitHub release;
`publish-images.yml` builds both architectures, pushes them to GHCR, then
**pulls each image back and smoke-tests it**.

### 4. Confirm it is actually installable

The Supervisor pulls the tag matching `version:` verbatim — there is no
fallback to `latest`, so a missing image is a 404 at install time, not a
warning:

```bash
tok=$(curl -s "https://ghcr.io/token?scope=repository:wetdognose/amd64-addon-claude-terminal:pull&service=ghcr.io" | jq -r .token)
curl -s -H "Authorization: Bearer $tok" \
  https://ghcr.io/v2/wetdognose/amd64-addon-claude-terminal/tags/list | jq -r '.tags[]'
```

Your new version should be listed. In Home Assistant, the add-on then offers
the update normally.

To watch the release as it runs — `-R` on **both** commands, since the inner
one selects which run to watch:

```bash
gh run watch -R WetDogNose/home-assistant-claude \
  $(gh run list -R WetDogNose/home-assistant-claude --workflow="Publish Images" \
    --limit 1 --json databaseId --jq '.[0].databaseId')
```

> [!TIP]
> **If the publish fails**, fix the cause and re-run it against the existing tag
> rather than re-tagging:
> ```bash
> gh workflow run publish-images.yml -R WetDogNose/home-assistant-claude --ref v2.5.1-wdn.2
> ```
> Deleting and re-pushing a tag works, but anyone who already pulled the old
> one keeps it.

---

## Community tools

Built by others to extend Claude Terminal:

- **[ha-ws-client-go](https://github.com/schoolboyqueue/home-assistant-blueprints/tree/main/scripts/ha-ws-client-go)** by [@schoolboyqueue](https://github.com/schoolboyqueue) — lightweight Go CLI for the HA WebSocket API: entity states, service calls, automation traces, live monitoring.
- **[Claude HA Plugins](https://github.com/ESJavadex/claude-homeassistant-plugins)** by [@ESJavadex](https://github.com/ESJavadex) — Claude Code skills for Home Assistant: YAML validation, pre-save hooks, Lovelace checks.
- **[Claude Terminal Pro](https://github.com/ESJavadex/claude-code-ha)** by [@ESJavadex](https://github.com/ESJavadex) — a fork adding image paste, package management and auto-install.

---

## Support

Problems with **this fork** → [this repository's issues](https://github.com/WetDogNose/home-assistant-claude/issues).

Please don't raise fork-specific problems upstream: the upstream maintainer did
not build these images and cannot reproduce changes made here. If it reproduces
on upstream's add-on too, report it [there](https://github.com/heytcass/home-assistant-addons/issues) instead.

---

## Upstream & attribution

The Claude Terminal add-on is the work of
**[Tom Cassady (@heytcass)](https://github.com/heytcass)** and contributors, in
**[heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons)**.
All credit for the original add-on belongs there.

This fork exists so the images Home Assistant pulls are built from source you
can inspect here — the add-on runs as root with broad access, so it is worth
controlling what actually ships. Both projects are MIT licensed.

Original work © Tom Cassady and contributors. See **[LICENSE](LICENSE)**.

<div align="center">
<sub>Built with Claude Code — development, debugging and documentation alike.</sub>
</div>
