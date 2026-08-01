#!/bin/bash

# Claude Terminal banner — compact, non-blocking header with version and tips.
# With --shell, drops into an interactive bash afterwards (shell mode).
# Runs inside ttyd/tmux (user-visible) — plain bash, no bashio.

TERRACOTTA='\033[38;2;217;119;87m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

version=$(cat /opt/scripts/addon-version 2>/dev/null || echo "unknown")

echo ""
echo -e "  ${TERRACOTTA}Claude Terminal${NC}  ${DIM}v${version} · Home Assistant app${NC}"
echo ""
echo -e "  ${WHITE}claude${NC}            start Claude Code  ${DIM}(-c continue · -r resume a session)${NC}"
echo -e "  ${WHITE}ha-diagnose${NC}       one-command HA & add-on system health check"
echo -e "  ${WHITE}ha-validate${NC}       validate HA YAML config (${DIM}--safe-edit <file>${NC})"
echo -e "  ${WHITE}ha-dashboard${NC}      generate Lovelace YAML dashboard (${DIM}<domain_or_area>${NC})"
echo -e "  ${WHITE}ha-mesh${NC}           scan Zigbee/Z-Wave/Matter mesh & battery health"
echo -e "  ${WHITE}ha-memory${NC}         search HA historical event & state transitions"
echo -e "  ${WHITE}ha-snapshot${NC}       capture camera image for Claude vision (${DIM}<entity>${NC})"
echo -e "  ${WHITE}ha-scaffold${NC}       scaffold integration or PyScript (${DIM}<domain>|pyscript${NC})"
echo -e "  ${WHITE}ha-git-backups${NC}    git config time-machine backup & rollback"
echo -e "  ${WHITE}ha-assist${NC}         query HA Assist voice pipeline"
echo -e "  ${WHITE}claude-bot${NC}        remote messaging gateway (${DIM}Telegram/Matrix/Discord${NC})"
echo -e "  ${WHITE}claude-cron${NC}       schedule background tasks (${DIM}add|list|remove${NC})"
echo -e "  ${WHITE}esphome-setup${NC}     install & persist ESPHome CLI"
echo -e "  ${WHITE}ha-tts${NC}            send TTS voice announcement to speaker"
echo -e "  ${WHITE}claude-doctor${NC}     diagnose network, auth, and environment issues"
echo -e "  ${WHITE}github-setup${NC}      sign in to GitHub so Claude can manage your repos"
echo -e "  ${WHITE}persist-install${NC}   install apk/pip packages that survive restarts"
echo -e "  ${WHITE}ha-context${NC}        refresh the Home Assistant context file for Claude"
echo -e "  ${DIM}Tip: Press Ctrl+B then 'h' inside tmux for the HA Helper Menu${NC}"
echo ""

if [ "$1" = "--shell" ]; then
    exec bash
fi
