#!/usr/bin/with-contenv bashio

# Claude Terminal — Claude Code in a browser terminal (ttyd + tmux).
#
# Startup philosophy: everything the terminal needs is baked into the image,
# and nothing on the boot path may depend on the network or block on input.
# Network work (Claude updates, HA context generation) happens in the
# background after the terminal is already available.

set -e
set -o pipefail

# Initialize environment for Claude Code CLI using /data (HA best practice)
init_environment() {
    # Use /data exclusively - guaranteed writable by HA Supervisor
    local data_home="/data/home"
    local config_dir="/data/.config"
    local cache_dir="/data/.cache"
    local state_dir="/data/.local/state"
    local claude_config_dir="/data/.config/claude"

    bashio::log.info "Initializing Claude Code environment in /data..."

    # Create all required directories
    if ! mkdir -p "$data_home" "$config_dir/claude" "$cache_dir" "$state_dir" "/data/.local"; then
        bashio::log.error "Failed to create directories in /data"
        exit 1
    fi

    # Set permissions
    chmod 755 "$data_home" "$config_dir" "$cache_dir" "$state_dir" "$claude_config_dir"

    # Set XDG and application environment variables
    export HOME="$data_home"
    export XDG_CONFIG_HOME="$config_dir"
    export XDG_CACHE_HOME="$cache_dir"
    export XDG_STATE_HOME="$state_dir"
    export XDG_DATA_HOME="/data/.local/share"

    # Claude-specific environment variables
    export ANTHROPIC_CONFIG_DIR="$claude_config_dir"
    export ANTHROPIC_HOME="/data"

    # The persistent native Claude install (see update_claude) must win over
    # the copy bundled in the image
    export PATH="$data_home/.local/bin:$PATH"

    # Older versions let the npm cache pile up here, inflating HA backups by
    # gigabytes (#103). The cache now lives in /tmp (npm_config_cache env).
    rm -rf "$data_home/.npm"

    # Migrate any existing authentication files from legacy locations
    migrate_legacy_auth_files "$claude_config_dir"

    # Install and configure tmux configuration in user home directory
    configure_tmux "$data_home"

    bashio::log.info "Environment initialized (HOME=${HOME})"
}

# Configure tmux configuration options based on add-on settings
configure_tmux() {
    local data_home="$1"
    if [ -f "/opt/scripts/tmux.conf" ]; then
        cp /opt/scripts/tmux.conf "$data_home/.tmux.conf"
        chmod 644 "$data_home/.tmux.conf"
    fi

    local mouse_enabled
    mouse_enabled=$(bashio::config 'tmux_mouse' 'false' 2>/dev/null) || mouse_enabled="false"
    [ -z "$mouse_enabled" ] || [ "$mouse_enabled" = "null" ] && mouse_enabled="false"

    if [ "$mouse_enabled" != "true" ]; then
        sed -i 's/set -g mouse on/set -g mouse off/' "$data_home/.tmux.conf" 2>/dev/null || true
        bashio::log.info "tmux mouse mode disabled (native browser text selection & URL clicks enabled)"
    else
        bashio::log.info "tmux mouse mode enabled"
    fi
}

# One-time migration of existing authentication files
migrate_legacy_auth_files() {
    local target_dir="$1"
    local migrated=false

    # Check common legacy locations
    local legacy_locations=(
        "/root/.config/anthropic"
        "/root/.anthropic"
        "/config/claude-config"
        "/tmp/claude-config"
    )

    for legacy_path in "${legacy_locations[@]}"; do
        if [ -d "$legacy_path" ] && [ "$(ls -A "$legacy_path" 2>/dev/null)" ]; then
            bashio::log.info "Migrating auth files from: $legacy_path"

            # Copy files to new location
            if cp -r "$legacy_path"/* "$target_dir/" 2>/dev/null; then
                # Set proper permissions
                find "$target_dir" -type f -exec chmod 600 {} \;

                # Create compatibility symlink if this is a standard location
                if [[ "$legacy_path" == "/root/.config/anthropic" ]] || [[ "$legacy_path" == "/root/.anthropic" ]]; then
                    rm -rf "$legacy_path"
                    ln -sf "$target_dir" "$legacy_path"
                fi

                migrated=true
                bashio::log.info "Migration completed from: $legacy_path"
            else
                bashio::log.warning "Failed to migrate from: $legacy_path"
            fi
        fi
    done

    if [ "$migrated" = false ]; then
        bashio::log.info "No legacy authentication files to migrate"
    fi
}

# Install user-facing commands into /usr/local/bin
setup_commands() {
    local entry name script
    for entry in \
        "welcome:/opt/scripts/welcome.sh" \
        "persist-install:/opt/scripts/persist-install.sh" \
        "ha-context:/opt/scripts/ha-context.sh" \
        "claude-doctor:/opt/scripts/health-check.sh" \
        "claude-login-url:/opt/scripts/claude-login-url.sh" \
        "github-setup:/opt/scripts/github-setup.sh" \
        "claude-launch:/opt/scripts/claude-launch.sh" \
        "data-gc:/opt/scripts/data-gc.sh" \
        "claude-api-server:/opt/scripts/claude-api-server.py" \
        "claude-login-notifier:/opt/scripts/claude-login-notifier.sh" \
        "ha-notify:/opt/scripts/ha-notify.sh" \
        "ha-snapshot:/opt/scripts/ha-snapshot.sh" \
        "ha-validate:/opt/scripts/ha-validate.sh" \
        "ha-scaffold:/opt/scripts/ha-scaffold.sh" \
        "esphome-setup:/opt/scripts/esphome-setup.sh" \
        "ha-tts:/opt/scripts/ha-tts.sh" \
        "claude-cron:/opt/scripts/claude-cron.sh" \
        "ha-diagnose:/opt/scripts/ha-diagnose.sh" \
        "ha-dashboard:/opt/scripts/ha-dashboard.sh" \
        "ha-mesh:/opt/scripts/ha-mesh.sh" \
        "ha-assist:/opt/scripts/ha-assist.sh" \
        "ha-memory:/opt/scripts/ha-memory.sh" \
        "claude-bot:/opt/scripts/claude-bot.sh" \
        "ha-git-backups:/opt/scripts/ha-git-backups.sh"; do
        name="${entry%%:*}"
        script="${entry#*:}"
        if [ -f "$script" ]; then
            cp "$script" "/usr/local/bin/$name"
            chmod +x "/usr/local/bin/$name"
        else
            bashio::log.warning "Script not found: $script"
        fi
    done

    # Write add-on version for the welcome banner (no bashio inside ttyd)
    bashio::addon.version > /opt/scripts/addon-version 2>/dev/null \
        || echo "unknown" > /opt/scripts/addon-version
}

# Keep Claude Code current. The bundled copy in the image is frozen at build
# time, so install the official native build into /data (persists across
# restarts and add-on updates) and refresh it in the background on each
# boot. Approach adapted from #104 by @WKassebaum.
# A native install being executable (-x) is not the same as it being
# runnable. The native build is dynamically linked, so a libc symbol
# mismatch — e.g. an older base image's musl lacking `posix_getdents`,
# which recent Claude Code builds relocate against — makes the binary abort
# on launch with a relocation error even though the file is present and +x.
# Such a binary still wins on PATH over the bundled copy and takes the whole
# terminal down with it (ttyd runs `tmux new-session ... 'claude'`, so the
# tmux session dies the instant claude does). Treat "installed" and
# "actually runs" as separate facts. The timeout keeps a wedged binary from
# blocking the boot path (this check runs before ttyd starts).
native_claude_runs() {
    timeout 10 "$HOME/.local/bin/claude" --version >/dev/null 2>&1
}

# Remove a persistent native install that exists but cannot execute in this
# image (typically a libc mismatch), so it stops shadowing the working
# bundled copy at /usr/local/bin/claude on PATH. This must run regardless of
# the auto-update setting — a broken +x binary is what takes the terminal
# down, and disabling auto-update does not remove it. Returns 0 if a usable
# native install remains, 1 otherwise.
ensure_native_claude_usable() {
    [ -x "$HOME/.local/bin/claude" ] || return 1
    if native_claude_runs; then
        return 0
    fi
    bashio::log.warning "Persistent Claude Code is present but fails to run (likely a libc mismatch); removing it and falling back to the bundled copy"
    rm -f "$HOME/.local/bin/claude"
    return 1
}

# Optional Claude Code version pin.
#
# This is the user-facing escape hatch for the one dependency that cannot be
# tested ahead of time: Claude Code re-installs itself from the network on
# every boot, weeks after any image was built, so no CI check observes it. When
# an upstream release cannot run in this image, pinning turns that from "wait
# for a new add-on release" into a configuration change.
#
# The official installer takes [stable|latest|VERSION]; validate before passing
# it through so a typo becomes a warning rather than a silently failed install.
claude_version_pin() {
    local pin
    pin=$(bashio::config 'claude_version' '')

    if [ -z "$pin" ] || [ "$pin" = "null" ]; then
        return 1
    fi

    if ! echo "$pin" | grep -qE '^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+([^[:space:]]*)?)$'; then
        bashio::log.warning "Ignoring invalid claude_version '${pin}' (expected: stable, latest, or X.Y.Z)"
        return 1
    fi

    echo "$pin"
}


# Install the native Claude Code build WITHOUT piping a remote script into a
# root shell.
#
# The previous approach ran `curl -fsSL https://claude.ai/install.sh | bash` as
# root on every boot: unauthenticated-to-us remote code, executed with full
# privileges, on a schedule, on an appliance that also holds Home Assistant
# credentials. Nothing about the add-on required that -- the installer's real
# job is to fetch a platform tarball, which is four lines of curl and tar, and
# is exactly what the Dockerfile already does for the bundled copy.
#
# Fetching directly also lets us verify BEFORE the binary reaches PATH: check
# relocations resolve and that it actually runs, rather than discovering both
# when the terminal dies.
install_claude_native() {
    local want="$1" pkg version tmp current

    case "$(apk --print-arch)" in
        x86_64)  pkg="linux-x64-musl" ;;
        aarch64) pkg="linux-arm64-musl" ;;
        *) bashio::log.warning "No native Claude build for $(apk --print-arch)"; return 1 ;;
    esac

    if [ -z "$want" ] || [ "$want" = "latest" ] || [ "$want" = "stable" ]; then
        version=$(curl -fsSL --connect-timeout 10 \
            https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
            | jq -r .version 2>/dev/null)
    else
        version="$want"
    fi
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        bashio::log.warning "Could not determine a Claude Code version to install"
        return 1
    fi

    # Skip the ~85MB download when the wanted version is already in place.
    if [ -x "$HOME/.local/bin/claude" ]; then
        current=$(timeout 10 "$HOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}')
        if [ "$current" = "$version" ]; then
            bashio::log.info "Claude Code ${version} already installed"
            return 0
        fi
    fi

    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL --connect-timeout 10 \
        "https://registry.npmjs.org/@anthropic-ai/claude-code-${pkg}/-/claude-code-${pkg}-${version}.tgz" \
        2>/dev/null | tar -xz -C "$tmp" package/claude 2>/dev/null; then
        bashio::log.warning "Download of Claude Code ${version} failed"
        rm -rf "$tmp"; return 1
    fi
    chmod 0755 "$tmp/package/claude"

    # Verify before it can shadow the bundled copy on PATH: a binary that is
    # present and +x but cannot relocate is exactly the 2.5.1 blank terminal.
    if ldd "$tmp/package/claude" 2>&1 | grep -q 'symbol not found' \
       || ! timeout 15 "$tmp/package/claude" --version >/dev/null 2>&1; then
        bashio::log.warning "Claude Code ${version} does not run in this image; keeping the bundled copy"
        rm -rf "$tmp"; return 1
    fi

    mkdir -p "$HOME/.local/bin"
    mv -f "$tmp/package/claude" "$HOME/.local/bin/claude"
    rm -rf "$tmp"
    bashio::log.info "Claude Code ${version} installed and verified"
    return 0
}

update_claude() {
    # Always neutralise a broken persistent install first, even when
    # auto-update is off, so it can't keep shadowing the bundled copy.
    # Capture via `|| native_usable=$?` so the intentional non-zero return
    # (no/removed native install) doesn't trip `set -e` and abort startup.
    local native_usable=0
    ensure_native_claude_usable || native_usable=$?

    if [ "$(bashio::config 'claude_auto_update' 'true')" != "true" ]; then
        if [ "$native_usable" -eq 0 ]; then
            bashio::log.info "Claude auto-update disabled; using persistent Claude Code"
        else
            bashio::log.info "Claude auto-update disabled; using bundled Claude Code"
        fi
        return 0
    fi

    # A pin means "install exactly this", so skip `claude update` entirely --
    # updating would immediately move off the version the user pinned to.
    local pin=""
    pin=$(claude_version_pin) || pin=""
    if [ -n "$pin" ]; then
        bashio::log.info "Installing pinned Claude Code ${pin} into /data (background)..."
        ( install_claude_native "$pin" || rm -f "$HOME/.local/bin/claude" ) &
        return 0
    fi

    if [ "$native_usable" -eq 0 ]; then
        bashio::log.info "Persistent Claude Code found; checking for updates in background"
        # install_claude_native verifies before replacing, so a bad upstream
        # build never lands on PATH in the first place -- no rollback needed.
        ( install_claude_native "latest" || true ) &
        return 0
    fi

    bashio::log.info "Installing persistent Claude Code into /data (background)..."
    ( install_claude_native "latest" || rm -f "$HOME/.local/bin/claude" ) &
}

# Install persistent packages from config and saved state
install_persistent_packages() {
    local persist_config="/data/persistent-packages.json"
    local apk_packages=""
    local pip_packages=""

    # Collect APK packages from Home Assistant config
    if bashio::config.has_value 'persistent_apk_packages'; then
        local config_apk
        config_apk=$(bashio::config 'persistent_apk_packages')
        if [ -n "$config_apk" ] && [ "$config_apk" != "null" ]; then
            apk_packages="$config_apk"
        fi
    fi

    # Collect pip packages from Home Assistant config
    if bashio::config.has_value 'persistent_pip_packages'; then
        local config_pip
        config_pip=$(bashio::config 'persistent_pip_packages')
        if [ -n "$config_pip" ] && [ "$config_pip" != "null" ]; then
            pip_packages="$config_pip"
        fi
    fi

    # Also check local persist-install config file
    if [ -f "$persist_config" ]; then
        local local_apk local_pip
        local_apk=$(jq -r '.apk_packages | join(" ")' "$persist_config" 2>/dev/null || echo "")
        if [ -n "$local_apk" ]; then
            apk_packages="$apk_packages $local_apk"
        fi

        local_pip=$(jq -r '.pip_packages | join(" ")' "$persist_config" 2>/dev/null || echo "")
        if [ -n "$local_pip" ]; then
            pip_packages="$pip_packages $local_pip"
        fi
    fi

    # Trim whitespace and remove duplicates
    apk_packages=$(echo "$apk_packages" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)
    pip_packages=$(echo "$pip_packages" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

    # Install APK packages
    if [ -n "$apk_packages" ]; then
        bashio::log.info "Installing persistent APK packages: $apk_packages"
        # shellcheck disable=SC2086
        if apk add --no-cache $apk_packages; then
            bashio::log.info "APK packages installed successfully"
        else
            bashio::log.warning "Some APK packages failed to install"
        fi
    fi

    # Install pip packages
    if [ -n "$pip_packages" ]; then
        bashio::log.info "Installing persistent pip packages: $pip_packages"
        # shellcheck disable=SC2086
        if pip3 install --break-system-packages --no-cache-dir $pip_packages; then
            bashio::log.info "pip packages installed successfully"
        else
            bashio::log.warning "Some pip packages failed to install"
        fi
    fi
}

# Configure git for use from the terminal.
#
# Both halves are purely local config writes, so this is safe on the boot path
# — no network, nothing to block on. GitHub itself is authenticated
# interactively via `github-setup`; there is deliberately no token option,
# because /data/options.json is plaintext and rides along in HA backups.
configure_git() {
    local git_name git_email
    git_name=$(bashio::config 'git_user_name' '')
    git_email=$(bashio::config 'git_user_email' '')

    # $HOME is /data/home, so ~/.gitconfig persists across restarts
    if [ -n "$git_name" ] && [ "$git_name" != "null" ]; then
        git config --global user.name "$git_name" \
            || bashio::log.warning "Failed to set git user.name"
    fi
    if [ -n "$git_email" ] && [ "$git_email" != "null" ]; then
        git config --global user.email "$git_email" \
            || bashio::log.warning "Failed to set git user.email"
    fi

    # Register gh as git's credential helper so `git push` works over HTTPS.
    # Gated on the credentials file existing rather than on `gh auth status`,
    # which would put a network call on the boot path.
    if [ -f "${XDG_CONFIG_HOME}/gh/hosts.yml" ]; then
        if gh auth setup-git >/dev/null 2>&1; then
            bashio::log.info "GitHub CLI authenticated; git credential helper configured"
        else
            bashio::log.warning "gh auth setup-git failed; 'git push' may prompt for credentials"
        fi
    else
        bashio::log.info "GitHub CLI not authenticated; run 'github-setup' in the terminal to sign in"
    fi
}

# Generate Home Assistant context file for Claude sessions (background —
# a slow Supervisor API must never delay the terminal)
generate_ha_context() {
    if [ "$(bashio::config 'ha_smart_context' 'true')" != "true" ]; then
        bashio::log.info "HA Smart Context disabled in configuration"
        return 0
    fi

    if [ -f /usr/local/bin/ha-context ]; then
        bashio::log.info "Generating Home Assistant context in background"
        (/usr/local/bin/ha-context >/dev/null 2>&1 || true) &
    fi
}

# Build extra flags for every claude launch.
# Note: the value is word-split; quoted multi-word arguments are not
# re-parsed (documented limitation).
build_claude_flags() {
    local flags=""

    if [ "$(bashio::config 'dangerously_skip_permissions' 'false')" = "true" ]; then
        flags="--dangerously-skip-permissions"
    fi

    local extra
    extra=$(bashio::config 'claude_extra_args' '')
    if [ -n "$extra" ] && [ "$extra" != "null" ]; then
        flags="${flags:+$flags }$extra"
    fi

    echo "$flags"
}

# Determine the command ttyd runs for each client connection
get_claude_launch_command() {
    local flags="$1"

    if [ "$(bashio::config 'auto_launch_claude' 'true')" = "true" ]; then
        # tmux -A attaches to the live session on browser reconnects and HA
        # navigation instead of stacking new ones.
        # claude-launch rather than claude: ttyd resolves this command on every
        # connection, so a binary broken by a background self-update after boot
        # would otherwise kill the tmux session instantly (the 2.5.1 symptom).
        # The wrapper probes, falls back to the bundled copy, and degrades to a
        # shell with an explanation rather than vanishing.
        echo "tmux new-session -A -s claude 'claude-launch${flags:+ $flags}'"
    else
        # Shell mode: banner + interactive bash, still inside tmux for
        # reconnect persistence. Run 'claude' manually when ready.
        echo "tmux new-session -A -s claude '/usr/local/bin/welcome --shell'"
    fi
}

# Background provisioning. Writes a sentinel so claude-launch can tell the
# difference between "still working" and "finished", and records a reason on
# failure so the terminal can explain itself instead of silently lacking tools.
PROVISION_DIR="/run/claude-terminal"

provision_async() {
    mkdir -p "$PROVISION_DIR"
    rm -f "$PROVISION_DIR/provisioned" "$PROVISION_DIR/failed"

    local failed=""
    install_persistent_packages || failed="package installation"
    setup_ha_mcp                || failed="${failed:+$failed, }ha-mcp setup"
    generate_ha_context         || failed="${failed:+$failed, }HA context"

    if [ -n "$failed" ]; then
        echo "$failed" > "$PROVISION_DIR/failed"
        bashio::log.warning "Background provisioning had problems: ${failed}"
        # The add-on log is not somewhere anyone looks until they already
        # suspect a problem; the notification drawer is.
        /usr/local/bin/ha-notify \
            "Claude Terminal setup incomplete" \
            "Some setup did not finish: ${failed}. The terminal still works, but Home Assistant tools may be unavailable. Check the add-on log for details." \
            "claude_terminal_provision" || true
    fi
    : > "$PROVISION_DIR/provisioned"
    bashio::log.info "Background provisioning complete"
}

# Start main web terminal
start_web_terminal() {
    local port=7681
    local flags
    flags=$(build_claude_flags)

    if [[ "$flags" == *"--dangerously-skip-permissions"* ]]; then
        bashio::log.warning "=========================================================="
        bashio::log.warning "dangerously_skip_permissions is ENABLED."
        bashio::log.warning "Claude will run tools without asking for confirmation."
        bashio::log.warning "It has write access to /config and can control Home"
        bashio::log.warning "Assistant through the Supervisor API and MCP."
        bashio::log.warning "=========================================================="
    fi

    local launch_command
    launch_command=$(get_claude_launch_command "$flags")

    bashio::log.info "Starting web terminal on port ${port} (auto_launch_claude=$(bashio::config 'auto_launch_claude' 'true'))"

    # Terminal theme - dark palette with terracotta accents (#d97757)
    local ttyd_theme='{"background":"#1a1b26","foreground":"#c0caf5","cursor":"#d97757","cursorAccent":"#1a1b26","selectionBackground":"#33467c","selectionForeground":"#c0caf5","black":"#15161e","red":"#f7768e","green":"#9ece6a","yellow":"#e0af68","blue":"#7aa2f7","magenta":"#bb9af7","cyan":"#7dcfff","white":"#a9b1d6","brightBlack":"#414868","brightRed":"#f7768e","brightGreen":"#9ece6a","brightYellow":"#e0af68","brightBlue":"#7aa2f7","brightMagenta":"#bb9af7","brightCyan":"#7dcfff","brightWhite":"#c0caf5"}'

    # Require the identity the Supervisor's ingress proxy already injects.
    #
    # panel_admin only hides the sidebar entry -- it is NOT access control, so
    # without this any authenticated Home Assistant user can mint an ingress
    # session and land on a root shell, and any co-resident add-on can reach
    # ttyd directly on the container network. ttyd answers 407 when the header
    # is absent, and applies the same check to the WebSocket upgrade, so the
    # data path cannot be opened around the HTTP gate.
    #
    # The dev escape hatch is deliberately gated on SUPERVISOR_TOKEN being
    # unset, so it can never disable enforcement inside a real add-on.
    # FAIL CLOSED. bashio::config returns empty when it cannot reach the
    # Supervisor API, so testing for "= true" meant a transient API failure
    # silently dropped authentication on a running add-on. Only an explicit
    # "false" disables it; anything else -- including an unreadable config --
    # enforces. Caught by ci/boot-test.sh, which saw HTTP 200 with no identity.
    local require_user auth_args=()
    require_user=$(bashio::config 'require_ingress_user' 'true' 2>/dev/null) || require_user="true"
    [ -z "$require_user" ] || [ "$require_user" = "null" ] && require_user="true"

    if [ "$require_user" != "false" ]; then
        auth_args=(--auth-header "X-Remote-User-Id")
        bashio::log.info "Ingress identity enforcement ON (set require_ingress_user: false if the terminal will not connect)"
    elif [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        # Off is the default, so this is information rather than an alarm. It
        # is still worth stating plainly: panel_admin hides the sidebar entry,
        # it does not restrict access.
        bashio::log.info "Ingress identity enforcement is off (default). Any Home Assistant"
        bashio::log.info "user can open this terminal. Set require_ingress_user: true to"
        bashio::log.info "restrict it -- if the terminal then fails to connect, your"
        bashio::log.info "installation does not forward the identity header; turn it back off."
    else
        # Local development only, and only when explicitly asked for: a missing
        # SUPERVISOR_TOKEN alone must never be enough to disable the gate.
        bashio::log.warning "require_ingress_user is false and there is no Supervisor: enforcement off (local development)"
    fi

    # Run ttyd with keepalive configuration to prevent WebSocket disconnects
    # See: https://github.com/heytcass/home-assistant-addons/issues/24
    exec ttyd \
        --port "${port}" \
        --interface 0.0.0.0 \
        --writable \
        ${auth_args[@]+"${auth_args[@]}"} \
        --ping-interval 30 \
        --client-option enableReconnect=true \
        --client-option reconnect=10 \
        --client-option reconnectInterval=5 \
        --client-option "theme=${ttyd_theme}" \
        --client-option fontSize=14 \
        bash -c "$launch_command"
}

# Setup ha-mcp (Home Assistant MCP Server) for Claude Code integration
setup_ha_mcp() {
    if [ -f "/opt/scripts/setup-ha-mcp.sh" ]; then
        bashio::log.info "Setting up Home Assistant MCP integration..."
        chmod +x /opt/scripts/setup-ha-mcp.sh
        # Source the script to get the configure function
        source /opt/scripts/setup-ha-mcp.sh
        configure_ha_mcp_server || bashio::log.warning "ha-mcp setup encountered issues but continuing..."
    fi
}

# Start Automation API server for Home Assistant automations
start_automation_api() {
    local enabled port custom_key token_file="/data/automation_api_token"
    enabled=$(bashio::config 'enable_automation_api' 'true' 2>/dev/null) || enabled="true"
    [ -z "$enabled" ] || [ "$enabled" = "null" ] && enabled="true"

    if [ "$enabled" = "false" ]; then
        bashio::log.info "Automation API server is disabled in options."
        return 0
    fi

    port=$(bashio::config 'automation_api_port' '8128' 2>/dev/null) || port="8128"
    custom_key=$(bashio::config 'automation_api_key' '' 2>/dev/null) || custom_key=""

    if [ -n "$custom_key" ] && [ "$custom_key" != "null" ]; then
        echo "$custom_key" > "$token_file"
        chmod 600 "$token_file"
        bashio::log.info "Automation API token set from options"
    elif [ ! -s "$token_file" ]; then
        local gen_token
        gen_token=$(hexdump -vn 16 -e '4/4 "%08x"' /dev/urandom 2>/dev/null || date +%s%N | md5sum | head -c 32)
        echo "$gen_token" > "$token_file"
        chmod 600 "$token_file"
        bashio::log.info "Generated new Automation API token in /data/automation_api_token"
    fi

    if [ -f "/usr/local/bin/claude-api-server" ]; then
        bashio::log.info "Starting Automation API server on port ${port}..."
        python3 /usr/local/bin/claude-api-server --port "${port}" --token-file "$token_file" &
    else
        bashio::log.warning "claude-api-server not found, skipping Automation API startup."
    fi
}

# Start Claude login URL notification daemon
start_login_notifier() {
    if [ -f "/usr/local/bin/claude-login-notifier" ]; then
        bashio::log.info "Starting Claude login URL notification daemon..."
        /usr/local/bin/claude-login-notifier &
    fi
}

# Start Claude Cron background daemon
start_claude_cron() {
    if [ -f "/usr/local/bin/claude-cron" ]; then
        bashio::log.info "Starting Claude Cron scheduled task daemon..."
        /usr/local/bin/claude-cron daemon &
    fi
}

# Copy automation blueprints if blueprints directory exists
sync_blueprints() {
    if [ -d "/config/blueprints/automation" ] && [ -f "/opt/blueprints/claude_automation_query.yaml" ]; then
        cp /opt/blueprints/claude_automation_query.yaml /config/blueprints/automation/claude_automation_query.yaml 2>/dev/null || true
        bashio::log.info "Synced Claude automation blueprint to /config/blueprints/automation/"
    fi
}

# Main execution
main() {
    bashio::log.info "Starting Claude Terminal add-on..."

    init_environment
    setup_commands
    update_claude
    configure_git
    start_automation_api
    start_login_notifier
    start_claude_cron
    sync_blueprints

    # Everything below this line used to run in the FOREGROUND before
    # exec ttyd: apk/pip installs with no timeout, and two cold starts of a
    # ~269MB binary for the MCP registration. On a Pi with persistent packages
    # configured, port 7681 stayed closed for a minute or more while the
    # Supervisor had already reported the add-on STARTED. That contradicts this
    # file's own rule (see the header) that nothing on the boot path may block.
    #
    # Serialised inside one subshell rather than three independent background
    # jobs: apk and pip must not race, and setup_ha_mcp needs a settled
    # environment. claude-launch waits on the sentinel with a bounded timeout,
    # so a wedged install degrades to "no MCP this session" rather than to a
    # terminal that never opens.
    provision_async &

    start_web_terminal
}

# Execute main function
main "$@"
