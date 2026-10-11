#!/bin/bash
# opencode-layers — write the two OpenCode config layers the add-on owns.
#
# OpenCode merges several config files, lowest priority first:
#
#   ~/.config/opencode/opencode.json   the USER layer (Claude and the user edit it)
#   $OPENCODE_CONFIG                    the DEFAULTS layer   <- written here
#   /etc/opencode/opencode.json         the ENFORCED layer   <- written here
#
# OpenCode would also read a PROJECT layer from the working directory
# (opencode.json and a .opencode/ directory). The add-on turns that off with
# OPENCODE_DISABLE_PROJECT_CONFIG, and it has to stay off: the working
# directory is /config, where files arrive from git clones, HACS, backups and
# shares, and OpenCode executes what it finds there without asking -- a
# .opencode/plugins/*.js is run as root at startup, an `mcp` entry's command
# is launched, and an agent definition can grant itself `bash: allow`.
#
# The add-on needs to contribute settings without ever rewriting the user's
# file -- the same constraint as claude-hooks and settings.json -- and OpenCode's
# native layering gives that for free. Both files written here live OUTSIDE
# /data, so they are regenerated on every boot and cannot outlive the release
# that wrote them.
#
# Two layers rather than one because they answer different questions:
#
#   defaults   things the add-on provides and the user may override: the
#              Home Assistant MCP server, the HA context file, language servers,
#              and the MCP servers shared from Claude Code.
#   enforced   things that must not be overridable: permissions, for the
#              built-in agents as well as globally, because an agent-level
#              permission block outranks the global one.
#
# Runs at boot (from run.sh) and again from `opencode-config mcp sync` inside
# the user's terminal -- plain bash, no bashio.
#
# Usage:
#   opencode-layers write     Write both layers from OC_* environment variables
#                             and record them for a later resync
#   opencode-layers resync    Rewrite both layers from the recorded values
#
# Environment (write):
#   OC_SKIP_PERMISSIONS  true = omit the permission block (allow by default)
#   OC_HA_MCP            true = register the Home Assistant MCP server
#   OC_HA_MCP_VERSION    ha-mcp version to run
#   OC_HA_CONTEXT        true = load the generated HA context file
#   OC_LSP               true = configure language servers
#   OC_SHARE_CLAUDE_MCP  true = copy Claude Code's MCP servers across

set -o pipefail

RUN_DIR="${OPENCODE_RUN_DIR:-/run/claude-terminal}"
DEFAULTS_FILE="${OPENCODE_DEFAULTS_FILE:-${RUN_DIR}/opencode-defaults.json}"
ENFORCED_FILE="${OPENCODE_ENFORCED_FILE:-/etc/opencode/opencode.json}"
RECORD_FILE="${OPENCODE_LAYERS_RECORD:-${RUN_DIR}/opencode-layers.env}"
SHARED_REPORT="${OPENCODE_SHARED_REPORT:-${RUN_DIR}/opencode-mcp-shared.json}"

CLAUDE_JSON="${CLAUDE_JSON:-${HOME}/.claude.json}"
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/config}"
CLAUDE_PROJECT_MCP="${CLAUDE_PROJECT_MCP:-${CLAUDE_PROJECT_DIR}/.mcp.json}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-${HOME}/.claude/settings.json}"
HA_CONTEXT_FILE="${HA_CONTEXT_FILE:-${HOME}/.claude/CLAUDE.md}"

DEFAULT_HA_MCP_VERSION="8.6.0"

warn() { echo "opencode-layers: $*" >&2; }

# Write a file atomically: a reader (OpenCode starting in another window) must
# never see a half-written config.
write_atomic() {
    local dest="$1" mode="$2" tmp
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    tmp=$(mktemp "${dest}.XXXXXX" 2>/dev/null) || return 1
    if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

# Print one MCP scope of Claude Code's config as a JSON object, or {} when the
# file is absent, unparseable, or has no servers there. An unreadable source
# must cost that source only -- never the whole layer.
read_scope() {
    local file="$1" filter="$2" out
    [ -s "$file" ] || { echo '{}'; return 0; }
    if ! out=$(jq -c --arg dir "$CLAUDE_PROJECT_DIR" \
        "(${filter}) as \$s | if (\$s | type) == \"object\" then \$s else {} end" \
        "$file" 2>/dev/null); then
        warn "could not parse ${file}; its MCP servers are not shared"
        echo '{}'
        return 0
    fi
    [ -n "$out" ] || out='{}'
    printf '%s\n' "$out"
}

# Translate Claude Code's MCP servers into OpenCode's shape.
#
# Emits {"servers": {...}, "skipped": [...], "unapproved": [...]}.
#
# /config/.mcp.json is NOT trusted on its own. It is a file in the project
# directory, and an entry in it is a command to run (or a URL to send headers
# to, which after the ${VAR} rewrite below could include the Supervisor
# token). Claude Code will not start a project-scope server until the user
# has approved it, and records that approval in files under $HOME -- which
# /config cannot write. A server is shared only when that approval exists, so
# sharing never grants a project file more trust than Claude Code already
# gave it. A settings file inside the project is deliberately not consulted:
# it could approve itself.
#
# Two names are never copied:
#   opencode        the bridge that lets Claude drive OpenCode. Copying it would
#                   have OpenCode calling itself.
#   home-assistant  the add-on writes its own entry, which references the
#                   Supervisor token instead of embedding the literal copy that
#                   `claude mcp add` stored.
# An entry that does not translate is reported, never guessed at.
translate_claude_mcp() {
    local user_scope local_scope project_scope
    user_scope=$(read_scope "$CLAUDE_JSON" '.mcpServers')
    local_scope=$(read_scope "$CLAUDE_JSON" '.projects[$dir].mcpServers')
    project_scope=$(read_scope "$CLAUDE_PROJECT_MCP" '.mcpServers')

    # The user's approvals of project-scope servers, from the two places
    # Claude Code keeps them. Unreadable means "nothing approved".
    local approvals_state approvals_settings
    approvals_state=$(read_scope "$CLAUDE_JSON" '.projects[$dir]
        | {enabledMcpjsonServers, disabledMcpjsonServers, enableAllProjectMcpServers}')
    approvals_settings=$(read_scope "$CLAUDE_SETTINGS" \
        '{enabledMcpjsonServers, disabledMcpjsonServers, enableAllProjectMcpServers}')

    jq -nc \
        --argjson user "$user_scope" \
        --argjson local "$local_scope" \
        --argjson project_all "$project_scope" \
        --argjson a1 "$approvals_state" \
        --argjson a2 "$approvals_settings" '
        # Claude Code expands ${VAR} in .mcp.json; OpenCode spells it {env:VAR}.
        def envrefs:
            walk(if type == "string"
                 then gsub("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)\\}"; "{env:\(.v)}")
                 else . end);
        def translate:
            if (.url | type) == "string" and (.command | type) != "string" then
                {type: "remote", url: .url}
                + (if (.headers | type) == "object" then {headers: .headers} else {} end)
                + {enabled: true}
            elif (.command | type) == "string" then
                {type: "local",
                 command: ([.command] + (if (.args | type) == "array" then (.args | map(tostring)) else [] end))}
                + (if (.env | type) == "object" then {environment: .env} else {} end)
                + {enabled: true}
            else null end;
        def names($k): [$a1, $a2 | .[$k] | if type == "array" then .[] else empty end];
        (names("enabledMcpjsonServers")) as $enabled
        | (names("disabledMcpjsonServers")) as $disabled
        | ($a1.enableAllProjectMcpServers == true or $a2.enableAllProjectMcpServers == true) as $all_enabled
        | ($project_all | with_entries(select(
              .key as $k
              | ($disabled | index($k)) == null
                and ($all_enabled or ($enabled | index($k)) != null)))) as $project
        | ([$project_all | keys[] | select(. as $k | $project | has($k) | not)]) as $unapproved
        | ($user + $local + $project) as $all
        | reduce ($all | to_entries[]) as $e ({servers: {}, skipped: [], unapproved: $unapproved};
            if $e.key == "opencode" or $e.key == "home-assistant" then .
            else ($e.value | if type == "object" then translate else null end) as $t
                | if $t == null then .skipped += [$e.key]
                  else .servers[$e.key] = ($t | envrefs) end
            end)'
}

build_enforced() {
    local skip="$1"
    # Fail SAFE: only an explicit "true" removes the prompts. An option that
    # could not be read arrives here as anything else and keeps them.
    #
    # The policy is "ask, except for tools that only read". OpenCode's own
    # default allows everything, and gating only edit and bash would still
    # leave web fetches and every MCP tool -- including the Home Assistant
    # ones, which can switch devices and restart Core -- running unprompted.
    # Order matters: OpenCode applies the LAST matching rule, so the catch-all
    # comes first.
    #
    # It is repeated under each built-in agent because an agent-level
    # permission block outranks the global one; without that, a `build` agent
    # redefined in the user layer would shed the policy.
    jq -n --arg skip "$skip" '
        {"*": "ask",
         read: "allow", glob: "allow", grep: "allow", list: "allow", lsp: "allow",
         todoread: "allow", todowrite: "allow", skill: "allow", task: "allow",
         question: "allow",
         edit: "ask", bash: "ask", external_directory: "ask"} as $policy
        | {"$schema": "https://opencode.ai/config.json", autoupdate: false}
        + (if $skip == "true" then {}
           else {permission: $policy,
                 agent: {build: {permission: $policy},
                         plan: {permission: $policy},
                         general: {permission: $policy}}} end)'
}

build_defaults() {
    local ha_mcp="$1" ha_mcp_version="$2" ha_context="$3" lsp="$4" shared="$5"
    jq -n \
        --arg ha_mcp "$ha_mcp" \
        --arg version "$ha_mcp_version" \
        --arg ha_context "$ha_context" \
        --arg context_file "$HA_CONTEXT_FILE" \
        --arg lsp "$lsp" \
        --argjson shared "$shared" '
        {"$schema": "https://opencode.ai/config.json"}
        + (if $ha_context == "true" then {instructions: [$context_file]} else {} end)
        + (if $lsp == "true" then {lsp: {
              # Routed through opencode-yaml-ls so Home Assistant tags reach the
              # server; see that script for why the built-in entry cannot do it.
              "yaml-ls": {
                  command: ["opencode-yaml-ls"],
                  extensions: [".yaml", ".yml"],
                  initialization: {yaml: {
                      keyOrdering: false,
                      customTags: [
                          "!include scalar",
                          "!include_dir_list scalar",
                          "!include_dir_named scalar",
                          "!include_dir_merge_list scalar",
                          "!include_dir_merge_named scalar",
                          "!secret scalar",
                          "!env_var scalar",
                          "!input scalar",
                          "!lambda scalar",
                          "!extend scalar",
                          "!remove scalar"
                      ]
                  }}
              }
           }} else {} end)
        + {mcp: (
              $shared
              + (if $ha_mcp == "true" then {"home-assistant": {
                    type: "local",
                    command: ["uvx", "--python", "3.13", "--index-strategy",
                              "unsafe-best-match", "ha-mcp@\($version)"],
                    environment: {
                        HOMEASSISTANT_URL: "http://supervisor/core",
                        # A reference, resolved by OpenCode at start: the token
                        # itself is never written to disk here.
                        HOMEASSISTANT_TOKEN: "{env:SUPERVISOR_TOKEN}"
                    },
                    enabled: true
                 }} else {} end)
          )}
        | if (.mcp | length) == 0 then del(.mcp) else . end'
}

# Record the option values so `resync` can rebuild the layers later without
# bashio, which the user's terminal does not have. Values are constrained to a
# known alphabet on the way in AND on the way out, so this file is never
# sourced and cannot carry anything executable.
record_inputs() {
    {
        printf 'OC_SKIP_PERMISSIONS=%s\n' "$OC_SKIP_PERMISSIONS"
        printf 'OC_HA_MCP=%s\n' "$OC_HA_MCP"
        printf 'OC_HA_MCP_VERSION=%s\n' "$OC_HA_MCP_VERSION"
        printf 'OC_HA_CONTEXT=%s\n' "$OC_HA_CONTEXT"
        printf 'OC_LSP=%s\n' "$OC_LSP"
        printf 'OC_SHARE_CLAUDE_MCP=%s\n' "$OC_SHARE_CLAUDE_MCP"
    } | write_atomic "$RECORD_FILE" 600
}

load_recorded() {
    [ -s "$RECORD_FILE" ] || return 1
    local key value
    while IFS='=' read -r key value; do
        case "$value" in *[!A-Za-z0-9._-]*) continue ;; esac
        case "$key" in
            OC_SKIP_PERMISSIONS) OC_SKIP_PERMISSIONS="$value" ;;
            OC_HA_MCP)           OC_HA_MCP="$value" ;;
            OC_HA_MCP_VERSION)   OC_HA_MCP_VERSION="$value" ;;
            OC_HA_CONTEXT)       OC_HA_CONTEXT="$value" ;;
            OC_LSP)              OC_LSP="$value" ;;
            OC_SHARE_CLAUDE_MCP) OC_SHARE_CLAUDE_MCP="$value" ;;
        esac
    done < "$RECORD_FILE"
}

normalise_inputs() {
    OC_SKIP_PERMISSIONS="${OC_SKIP_PERMISSIONS:-false}"
    OC_HA_MCP="${OC_HA_MCP:-false}"
    OC_HA_CONTEXT="${OC_HA_CONTEXT:-false}"
    OC_LSP="${OC_LSP:-false}"
    OC_SHARE_CLAUDE_MCP="${OC_SHARE_CLAUDE_MCP:-true}"
    OC_HA_MCP_VERSION="${OC_HA_MCP_VERSION:-$DEFAULT_HA_MCP_VERSION}"
    case "$OC_HA_MCP_VERSION" in
        *[!A-Za-z0-9._-]*)
            warn "ignoring invalid ha-mcp version '${OC_HA_MCP_VERSION}'"
            OC_HA_MCP_VERSION="$DEFAULT_HA_MCP_VERSION"
            ;;
    esac
}

# Exit status: 0 both written, 1 defaults failed, 2 enforced failed, 3 both.
# The caller treats them differently -- a missing defaults layer costs
# features, a missing enforced layer costs the confirmation prompts.
write_layers() {
    local rc=0 translated shared='{}' skipped='[]' unapproved='[]' enforced defaults

    if [ "$OC_SHARE_CLAUDE_MCP" = "true" ]; then
        if translated=$(translate_claude_mcp) && [ -n "$translated" ]; then
            shared=$(printf '%s' "$translated" | jq -c '.servers')
            skipped=$(printf '%s' "$translated" | jq -c '.skipped')
            unapproved=$(printf '%s' "$translated" | jq -c '.unapproved')
        else
            warn "could not read Claude Code's MCP servers; none are shared"
        fi
    fi

    if [ "$skipped" != "[]" ]; then
        warn "not shared (no OpenCode equivalent): $(printf '%s' "$skipped" | jq -r 'join(", ")')"
    fi

    if [ "$unapproved" != "[]" ]; then
        warn "not shared (in ${CLAUDE_PROJECT_MCP} but not approved in Claude Code): $(printf '%s' "$unapproved" | jq -r 'join(", ")')"
    fi

    if enforced=$(build_enforced "$OC_SKIP_PERMISSIONS") \
        && printf '%s\n' "$enforced" | write_atomic "$ENFORCED_FILE" 644; then
        :
    else
        warn "could not write ${ENFORCED_FILE}"
        rc=$((rc + 2))
    fi

    # 600: servers shared from Claude Code can carry credentials in their
    # environment or headers.
    if defaults=$(build_defaults "$OC_HA_MCP" "$OC_HA_MCP_VERSION" "$OC_HA_CONTEXT" "$OC_LSP" "$shared") \
        && printf '%s\n' "$defaults" | write_atomic "$DEFAULTS_FILE" 600; then
        :
    else
        warn "could not write ${DEFAULTS_FILE}"
        rc=$((rc + 1))
    fi

    # Names only -- claude-doctor and `opencode-config mcp list` read this.
    jq -nc --argjson shared "$shared" --argjson skipped "$skipped" --argjson unapproved "$unapproved" \
        '{shared: ($shared | keys), skipped: $skipped, unapproved: $unapproved}' \
        | write_atomic "$SHARED_REPORT" 644 || true

    return "$rc"
}

case "${1:-}" in
    write)
        normalise_inputs
        record_inputs || warn "could not record options; 'resync' will be unavailable"
        write_layers
        ;;
    resync)
        if ! load_recorded; then
            warn "no recorded options at ${RECORD_FILE}; restart the add-on to regenerate the layers"
            exit 1
        fi
        normalise_inputs
        write_layers
        ;;
    -h|--help|help)
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "Usage: opencode-layers write|resync" >&2
        exit 1
        ;;
esac
