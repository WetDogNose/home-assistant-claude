#!/bin/bash

# opencode-launch — pick an OpenCode binary that actually runs, then run it.
#
# The same job claude-launch does for Claude, for the same reason: OpenCode is
# a native musl binary that is updated in the background after boot, so
# "installed and +x" and "actually runs" are separate facts, and the check has
# to happen where the binary is started. A command that aborts inside a tmux
# window closes that window with the error unread.
#
# Usage:
#   opencode-launch [--wait] [opencode args...]
#
#   --wait   Show a banner and start OpenCode only when Enter is pressed. This
#            is how the add-on opens the second tmux window: OpenCode is a few
#            hundred MB resident, and a window nobody has looked at should not
#            cost that on a Raspberry Pi.
#
# Runs inside ttyd/tmux (user-visible) — plain bash, no bashio.

TERRACOTTA='\033[38;2;217;119;87m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

BUNDLED="/usr/local/bin/opencode"
PERSISTENT="${HOME}/.local/bin/opencode"
ENFORCED_FILE="${OPENCODE_ENFORCED_FILE:-/etc/opencode/opencode.json}"
STATE_FILE="${OPENCODE_STATE_FILE:-/data/opencode-state.json}"

WAIT="false"
if [ "${1:-}" = "--wait" ]; then
    WAIT="true"
    shift
fi

runs() {
    timeout 10 "$1" --version >/dev/null 2>&1
}

# OpenCode can exit -- or be killed -- in the middle of a turn, and then no
# plugin event ever reports the turn as over. Without this the busy sensor
# would stay on until the next add-on restart. Only when the state file exists:
# that is how run.sh says OpenCode's entities are enabled.
reset_entities() {
    [ -f "$STATE_FILE" ] || return 0
    command -v ha-entity >/dev/null 2>&1 || return 0
    ha-entity --agent opencode set busy=false status=idle >/dev/null 2>&1 || true
}

banner() {
    echo ""
    echo -e "  ${TERRACOTTA}OpenCode${NC}  ${DIM}the second agent in this terminal${NC}"
    echo ""
    echo -e "  ${DIM}Configure which API it talks to from the Claude window:${NC}"
    echo -e "    ${DIM}ask Claude to \"point OpenCode at <endpoint>\", or run${NC} opencode-config --help"
    echo ""
    echo -e "  ${DIM}Switch windows with${NC} Ctrl-b 1 ${DIM}(Claude) and${NC} Ctrl-b 2 ${DIM}(OpenCode).${NC}"
    echo ""
}

# The enforced layer is what makes OpenCode ask before editing files or running
# commands. If the add-on could not write it, OpenCode runs with its own
# allow-by-default permissions, and that must be said where it will be read.
warn_if_unenforced() {
    [ -s "$ENFORCED_FILE" ] && return 0
    if [ -n "${OPENCODE_PERMISSION:-}" ]; then
        # The environment copy of the policy still applies; what is lost is
        # the per-agent pinning only the file can do.
        echo -e "  ${YELLOW}The add-on's permission file for OpenCode is missing.${NC}"
        echo -e "  ${DIM}Prompts are still on, but a subagent may run commands without asking.${NC}"
        echo -e "  ${DIM}Restart the add-on and check its log.${NC}"
        echo ""
        return 0
    fi
    # Neither copy of the policy is present. Do not start allow-all and merely
    # say so: apply the policy here. If the user had asked for no prompts
    # (dangerously_skip_permissions) the enforced file would still exist, so
    # reaching this point always means something failed, and failing toward
    # "ask" is the safe direction.
    local policy=""
    command -v opencode-layers >/dev/null 2>&1 && policy=$(opencode-layers policy 2>/dev/null)
    if [ -n "$policy" ]; then
        export OPENCODE_PERMISSION="$policy"
        echo -e "  ${YELLOW}The add-on's permission settings for OpenCode were missing.${NC}"
        echo -e "  ${DIM}They have been applied for this session. Restart the add-on and check its log.${NC}"
        echo ""
        return 0
    fi
    echo -e "  ${YELLOW}OpenCode's permission settings could not be applied, so it will not be started.${NC}"
    echo -e "  ${DIM}Without them it would edit files and run commands without asking.${NC}"
    echo -e "  ${DIM}Restart the add-on and check its log.${NC}"
    echo ""
    return 1
}

if [ "$WAIT" = "true" ]; then
    banner
fi

# On every start, not only the first: this is the last point at which a
# missing policy can be caught before OpenCode has tools.
if ! warn_if_unenforced; then
    exec /usr/local/bin/welcome --shell
fi

if [ "$WAIT" = "true" ]; then
    echo -e "  Press ${TERRACOTTA}Enter${NC} to start OpenCode."
    read -r _
fi

for candidate in "$PERSISTENT" "$BUNDLED"; do
    [ -x "$candidate" ] || continue
    if runs "$candidate"; then
        # NOT exec, for the reason claude-launch gives: an exec'd process ends
        # the tmux window when it exits, taking any error it printed with it.
        "$candidate" "$@"
        status=$?
        reset_entities
        echo ""
        if [ "$status" -eq 0 ]; then
            echo -e "  ${DIM}OpenCode exited. Type 'opencode' to start again, or 'exit' to close.${NC}"
        else
            echo -e "  ${YELLOW}OpenCode exited with status ${status}.${NC}"
            echo -e "  ${DIM}Run 'opencode-config validate' to check its configuration, or 'claude-doctor'.${NC}"
        fi
        echo ""
        exec /usr/local/bin/welcome --shell
    fi
    echo "opencode-launch: ${candidate} is present but fails to run; trying fallback" >&2
done

# Neither copy runs. Stay in a shell: closing the window here would look like
# the window never existed.
reset_entities
echo ""
echo -e "  ${TERRACOTTA}OpenCode${NC}  ${YELLOW}could not be started${NC}"
echo ""
echo -e "  Neither copy of OpenCode runs in this container:"
for candidate in "$PERSISTENT" "$BUNDLED"; do
    if [ -x "$candidate" ]; then
        echo -e "    ${candidate}"
        timeout 10 "$candidate" --version 2>&1 | head -2 | sed 's/^/      /'
    else
        echo -e "    ${candidate} ${DIM}(not installed)${NC}"
    fi
done
echo ""
echo -e "  ${DIM}Try, in order:${NC}"
echo ""
echo -e "    claude-doctor                    ${DIM}# diagnose${NC}"
echo -e "    rm -f ${PERSISTENT}"
echo -e "    ${DIM}# then restart the add-on to reinstall${NC}"
echo ""
echo -e "  ${DIM}Pin a known-good build with the 'opencode_version' add-on option.${NC}"
echo -e "  ${DIM}Claude in window 1 is not affected.${NC}"
echo ""

exec /usr/local/bin/welcome --shell
