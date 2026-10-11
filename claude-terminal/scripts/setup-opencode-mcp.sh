#!/usr/bin/with-contenv bashio
# Register OpenCode with Claude Code as an MCP server, so Claude can hand work
# to OpenCode -- on whatever API endpoint OpenCode is configured for -- and
# read the result.
#
# OpenCode has no MCP server mode of its own. The bridge is `opencode-mcp`, a
# THIRD-PARTY package (one maintainer, MIT, not affiliated with the OpenCode
# project) that talks to `opencode serve` over HTTP. It runs as root beside the
# Supervisor token, which shapes everything below:
#
#   - It is installed at an EXACT version from an add-on option, never `latest`
#     and never through `npx` at session start, so what runs is what was
#     chosen and a Claude session never waits on the registry.
#   - npm lifecycle scripts are disabled for the install. The package is plain
#     JavaScript and needs none; a dependency that suddenly wants to run code
#     at install time should fail here rather than run.
#   - Its own dependencies use caret ranges and are NOT locked by the version
#     pin. That residual risk is documented in DOCS.md rather than hidden.
#
# Installed at runtime rather than baked into the image because npm crashes
# under QEMU in the aarch64 release build (the same reason Claude Code itself
# is fetched as a tarball). It lives under XDG_DATA_HOME so it downloads once,
# and is excluded from backups.
#
# Sourced by run.sh and called from provision_async -- never on the boot path.

set -e

OPENCODE_MCP_PREFIX="/data/.local/share/opencode-mcp"
OPENCODE_MCP_DEFAULT_VERSION="3.0.0"

configure_opencode_mcp_bridge() {
    local enabled opencode_enabled
    opencode_enabled=$(bashio::config 'enable_opencode' 'true' 2>/dev/null) || opencode_enabled=""
    enabled=$(bashio::config 'enable_opencode_mcp' 'true' 2>/dev/null) || enabled=""
    [ -z "$opencode_enabled" ] || [ "$opencode_enabled" = "null" ] && opencode_enabled="true"
    [ -z "$enabled" ] || [ "$enabled" = "null" ] && enabled="true"

    if [ "$opencode_enabled" != "true" ] || [ "$enabled" != "true" ]; then
        # Shipped state: a registration left by an earlier boot would point
        # Claude at tools that are now switched off.
        claude mcp remove opencode >/dev/null 2>&1 || true
        bashio::log.info "OpenCode MCP bridge is disabled in configuration"
        return 0
    fi

    if ! command -v npm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
        bashio::log.warning "npm/node not found - OpenCode MCP bridge skipped"
        return 1
    fi

    local version
    version=$(bashio::config 'opencode_mcp_version' "$OPENCODE_MCP_DEFAULT_VERSION" 2>/dev/null) || version=""
    if [ -z "$version" ] || [ "$version" = "null" ]; then version="$OPENCODE_MCP_DEFAULT_VERSION"; fi
    # Exact versions only. A range or a tag here would defeat the point of the
    # option, and the value is interpolated into an npm package spec.
    if ! echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'; then
        bashio::log.warning "Ignoring invalid opencode_mcp_version '${version}' (expected an exact X.Y.Z); using ${OPENCODE_MCP_DEFAULT_VERSION}"
        version="$OPENCODE_MCP_DEFAULT_VERSION"
    fi

    local package_json="${OPENCODE_MCP_PREFIX}/node_modules/opencode-mcp/package.json"
    local entry="${OPENCODE_MCP_PREFIX}/node_modules/opencode-mcp/dist/index.js"
    local installed=""
    [ -f "$package_json" ] && installed=$(jq -r '.version // empty' "$package_json" 2>/dev/null || true)

    if [ "$installed" != "$version" ] || [ ! -f "$entry" ]; then
        bashio::log.info "Installing OpenCode MCP bridge opencode-mcp@${version}..."
        # Start clean so a changed pin cannot leave the old version's
        # dependency tree mixed in with the new one.
        rm -rf "$OPENCODE_MCP_PREFIX"
        mkdir -p "$OPENCODE_MCP_PREFIX"
        if ! timeout 300 npm install --prefix "$OPENCODE_MCP_PREFIX" \
            --ignore-scripts --no-audit --no-fund --loglevel=error \
            "opencode-mcp@${version}" >/dev/null 2>&1; then
            bashio::log.warning "Could not install opencode-mcp@${version}; Claude will have no OpenCode tools"
            rm -rf "$OPENCODE_MCP_PREFIX"
            claude mcp remove opencode >/dev/null 2>&1 || true
            return 1
        fi
    fi

    if [ ! -f "$entry" ]; then
        bashio::log.warning "opencode-mcp@${version} installed without ${entry}; bridge skipped"
        claude mcp remove opencode >/dev/null 2>&1 || true
        return 1
    fi

    # Re-registered on every boot, like ha-mcp, so the registration tracks the
    # release and the pinned version rather than whatever an old boot wrote.
    claude mcp remove opencode >/dev/null 2>&1 || true

    # OPENCODE_AUTO_SERVE: the bridge starts `opencode serve` on loopback when
    #   Claude first uses a tool and stops it when the Claude session ends, so
    #   nothing listens and nothing is resident while the feature is unused.
    # OPENCODE_TOOL_PROFILE=essential: the full profile adds about 70 tool
    #   definitions to every Claude session's context.
    if claude mcp add opencode \
        --env "OPENCODE_AUTO_SERVE=true" \
        --env "OPENCODE_BASE_URL=http://127.0.0.1:4096" \
        --env "OPENCODE_TOOL_PROFILE=essential" \
        -- node "$entry" >/dev/null 2>&1; then
        bashio::log.info "OpenCode MCP bridge ${version} registered with Claude Code"
    else
        bashio::log.warning "Failed to register the OpenCode MCP bridge with Claude Code"
        return 1
    fi
}
