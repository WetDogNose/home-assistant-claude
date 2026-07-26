# Claude Terminal for Home Assistant (WetDogNose fork)

This repository contains a custom add-on that integrates Anthropic's Claude Code CLI with Home Assistant.

It is a fork of [heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons) — see [Upstream & attribution](#upstream--attribution).

## Installation

1. In Home Assistant, go to **Settings** → **Add-ons** → **Add-on Store**
2. Click the **⋮** menu in the top right and choose **Repositories**
3. Add the URL: `https://github.com/WetDogNose/home-assistant-claude`
4. Click **Add**, then close the dialog
5. Find **Claude Terminal (WetDogNose)** in the store and click **Install**
6. Start the add-on, then click **OPEN WEB UI** (or use the sidebar entry)
7. On first launch, follow the OAuth prompts to sign in to your Anthropic account

Home Assistant pulls prebuilt images from `ghcr.io/wetdognose`, so installing
does not build anything on your Home Assistant machine.

> **Installs alongside the original.** This fork uses the slug
> `claude_terminal_wdn`, distinct from upstream's `claude_terminal`, so both
> can be installed at once. They keep separate `/data`, which means a separate
> Claude login and separate session history for each.

## Add-ons

### Claude Terminal

A web-based terminal interface with Claude Code CLI pre-installed. This add-on provides a terminal environment directly in your Home Assistant dashboard, allowing you to use Claude's powerful AI capabilities for coding, automation, and configuration tasks.

Features:
- Web terminal access through your Home Assistant UI
- Pre-installed Claude Code CLI that launches automatically
- Direct access to your Home Assistant config directory
- No configuration needed (uses OAuth)
- Access to Claude's complete capabilities including:
  - Code generation and explanation
  - Debugging assistance
  - Home Assistant automation help
  - Learning resources

[Documentation](claude-terminal/DOCS.md)

## Community Tools

Tools built by the community to enhance Claude Terminal:

- **[ha-ws-client-go](https://github.com/schoolboyqueue/home-assistant-blueprints/tree/main/scripts/ha-ws-client-go)** by [@schoolboyqueue](https://github.com/schoolboyqueue) - Lightweight Go CLI for Home Assistant WebSocket API. Gives Claude direct access to entity states, service calls, automation traces, and real-time monitoring. Single binary, no dependencies.

- **[Claude Home Assistant Plugins](https://github.com/ESJavadex/claude-homeassistant-plugins)** by [@ESJavadex](https://github.com/ESJavadex) - A collection of Claude Code skills/plugins for Home Assistant, including YAML validation, pre-save hooks, and Lovelace dashboard validation.

- **[Claude Terminal Pro](https://github.com/ESJavadex/claude-code-ha)** by [@ESJavadex](https://github.com/ESJavadex) - A fork with additional features including image paste support, persistent package management, and auto-install configuration.

## Support

Issues with **this fork** belong in [this repository's issue tracker](https://github.com/WetDogNose/home-assistant-claude/issues).

Please don't raise fork-specific problems upstream — the upstream maintainer
did not build these images and can't reproduce changes made here. If you can
reproduce a problem on upstream's add-on too, report it
[there](https://github.com/heytcass/home-assistant-addons/issues) instead.

## Upstream & attribution

The Claude Terminal add-on is the work of
**[Tom Cassady (@heytcass)](https://github.com/heytcass)** and contributors, in
[heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons).
All credit for the original add-on belongs there.

This fork exists so the images Home Assistant pulls are built from this
repository rather than from a third-party registry — the add-on runs as root
with broad access to Home Assistant, so it's worth controlling what actually
ships. Both projects are MIT licensed.

Original work © Tom Cassady and contributors. See [LICENSE](LICENSE).

## Credits

This add-on was created with the assistance of Claude Code itself! The development process, debugging, and documentation were all completed using Claude's AI capabilities.

## License

This repository is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
