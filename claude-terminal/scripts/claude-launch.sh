#!/bin/bash

# claude-launch — pick a Claude binary that actually runs, then exec it.
#
# Why this exists, and why the boot-time guard in run.sh is not enough:
# ttyd resolves its launch command on EVERY client connection, but
# ensure_native_claude_usable runs once, at boot. Claude Code self-updates in
# the background, so a build that cannot run in this image can appear *after*
# boot. Because ttyd runs "tmux new-session -A -s claude '<cmd>'", the tmux
# session dies the instant that command aborts — the user sees a terminal that
# opens and immediately closes, with the error scrolled away or never drawn.
# That is the 2.5.1 symptom, and it is a launch-time property, so the check
# belongs here.
#
# Probing costs one exec of --version per connection. A binary that cannot
# relocate fails that immediately (the loader errors before main), so the
# timeout is a ceiling for a hung binary, not the usual path.
#
# Runs inside ttyd/tmux (user-visible) — plain bash, no bashio.

TERRACOTTA='\033[38;2;217;119;87m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

BUNDLED="/usr/local/bin/claude"
PERSISTENT="${HOME}/.local/bin/claude"
PROVISION_DIR="/run/claude-terminal"

# Provisioning (package installs, ha-mcp registration, HA context) now runs in
# the background so the terminal opens immediately. Claude reads its MCP config
# at startup, though, so a session launched mid-provision would silently have no
# Home Assistant tools. Wait -- but bounded, because a wedged apk must degrade
# to "no MCP this session", never to a terminal that never opens.
wait_for_provisioning() {
    [ -d "$PROVISION_DIR" ] || return 0
    [ -f "$PROVISION_DIR/provisioned" ] && return 0

    local waited=0
    printf '  Preparing environment'
    while [ ! -f "$PROVISION_DIR/provisioned" ] && [ "$waited" -lt 60 ]; do
        printf '.'
        sleep 2
        waited=$(( waited + 2 ))
    done
    echo ""

    if [ -f "$PROVISION_DIR/failed" ]; then
        echo -e "  ${YELLOW}Some setup did not complete: $(cat "$PROVISION_DIR/failed")${NC}"
        echo -e "  ${DIM}Home Assistant tools may be unavailable. Check the add-on log.${NC}"
        echo ""
    elif [ ! -f "$PROVISION_DIR/provisioned" ]; then
        echo -e "  ${YELLOW}Setup is taking longer than expected; starting anyway.${NC}"
        echo ""
    fi
}

wait_for_provisioning

runs() {
    timeout 10 "$1" --version >/dev/null 2>&1
}

# Prefer the persistent self-updating install, fall back to the copy baked into
# the image. PATH order would pick the same first choice, but resolving the
# paths explicitly means the fallback still works when the first one is broken.
for candidate in "$PERSISTENT" "$BUNDLED"; do
    [ -x "$candidate" ] || continue
    if runs "$candidate"; then
        exec "$candidate" "$@"
    fi
    echo "claude-launch: ${candidate} is present but fails to run; trying fallback" >&2
done

# Neither copy runs. Drop to a shell instead of exiting, because exiting here
# is indistinguishable from a broken add-on: tmux would close and the browser
# terminal would go blank with nothing to read.
echo ""
echo -e "  ${TERRACOTTA}Claude Terminal${NC}  ${YELLOW}Claude Code could not be started${NC}"
echo ""
echo -e "  Neither copy of Claude Code runs in this container:"
for candidate in "$PERSISTENT" "$BUNDLED"; do
    if [ -x "$candidate" ]; then
        echo -e "    ${candidate}"
        timeout 10 "$candidate" --version 2>&1 | head -2 | sed 's/^/      /'
    else
        echo -e "    ${candidate} ${DIM}(not installed)${NC}"
    fi
done
echo ""
echo -e "  ${DIM}This usually means an update pulled a build incompatible with${NC}"
echo -e "  ${DIM}this image. Try, in order:${NC}"
echo ""
echo -e "    claude-doctor                    ${DIM}# diagnose${NC}"
echo -e "    rm -f ${PERSISTENT}"
echo -e "    ${DIM}# then restart the add-on to reinstall${NC}"
echo ""
echo -e "  ${DIM}Pin a known-good build with the 'claude_version' add-on option${NC}"
echo -e "  ${DIM}to stop an update reintroducing this.${NC}"
echo ""

exec /usr/local/bin/welcome --shell
