#!/usr/bin/with-contenv bashio

# Health check script for Claude Terminal add-on
# Validates environment and provides diagnostic information

check_system_resources() {
    bashio::log.info "=== System Resources Check ==="

    # Check available memory
    local mem_total mem_free
    mem_total=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    mem_free=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    bashio::log.info "Memory: ${mem_free}MB free of ${mem_total}MB total"

    if [ "$mem_free" -lt 256 ]; then
        bashio::log.error "Low memory warning: Less than 256MB available"
        bashio::log.info "This may cause installation or runtime issues"
    fi

    # Check disk space in /data
    local disk_free
    disk_free=$(df -m /data | tail -1 | awk '{print $4}')
    bashio::log.info "Disk space in /data: ${disk_free}MB free"

    if [ "$disk_free" -lt 100 ]; then
        bashio::log.error "Low disk space warning: Less than 100MB in /data"
    fi
}

check_directory_permissions() {
    bashio::log.info "=== Directory Permissions Check ==="

    # Check if /data is writable
    if [ -w "/data" ]; then
        bashio::log.info "/data directory: Writable ✓"
    else
        bashio::log.error "/data directory: Not writable ✗"
        return 1
    fi

    # Try to create test directory
    local test_dir="/data/.test_$$"
    if mkdir -p "$test_dir" 2>/dev/null; then
        bashio::log.info "Can create directories in /data ✓"
        rmdir "$test_dir"
    else
        bashio::log.error "Cannot create directories in /data ✗"
        return 1
    fi
}

check_node_installation() {
    bashio::log.info "=== Node.js Installation Check ==="

    if command -v node >/dev/null 2>&1; then
        local node_version
        node_version=$(node --version)
        bashio::log.info "Node.js installed: $node_version ✓"
    else
        bashio::log.error "Node.js not found ✗"
        return 1
    fi

    if command -v npm >/dev/null 2>&1; then
        local npm_version
        npm_version=$(npm --version)
        bashio::log.info "npm installed: $npm_version ✓"
    else
        bashio::log.error "npm not found ✗"
        return 1
    fi
}

check_claude_cli() {
    bashio::log.info "=== Claude CLI Check ==="

    # Deliberately runs the binary rather than testing for presence and the
    # executable bit. The 2.5.1 failure was a binary that satisfied both and
    # still aborted on exec, so a presence check reports a healthy CLI during
    # the exact outage this diagnostic exists to explain.
    local found_working=1
    local candidate version
    for candidate in "${HOME}/.local/bin/claude" "/usr/local/bin/claude"; do
        if [ ! -x "$candidate" ]; then
            bashio::log.info "${candidate}: not installed"
            continue
        fi
        if version=$(timeout 20 "$candidate" --version 2>&1); then
            bashio::log.info "${candidate}: runs ✓ (${version})"
            found_working=0
        else
            bashio::log.error "${candidate}: present but FAILS to run ✗"
            bashio::log.error "  ${version}"
            bashio::log.info "  This is what produces a blank terminal. Remove it and restart,"
            bashio::log.info "  or pin a known-good build with the claude_version option."
        fi
    done

    if [ "$found_working" -ne 0 ]; then
        bashio::log.error "No working Claude CLI found ✗"
        return 1
    fi

    # Which one actually wins on PATH is what the terminal will launch
    if command -v claude >/dev/null 2>&1; then
        bashio::log.info "PATH resolves claude to: $(command -v claude)"
    fi
}

check_github_cli() {
    bashio::log.info "=== GitHub CLI Check ==="

    if ! command -v gh >/dev/null 2>&1; then
        bashio::log.error "gh not found ✗"
        return 1
    fi
    bashio::log.info "gh installed: $(gh --version 2>/dev/null | head -1) ✓"

    # Check the credentials file before calling gh auth status, so an
    # unauthenticated add-on reports instantly instead of waiting on a network
    # round trip that is expected to fail
    local hosts_file="${XDG_CONFIG_HOME:-$HOME/.config}/gh/hosts.yml"
    if [ ! -f "$hosts_file" ]; then
        bashio::log.warning "gh is not signed in - run 'github-setup' in the terminal"
        return 0
    fi

    if gh auth status >/dev/null 2>&1; then
        bashio::log.info "gh authenticated ✓"
    else
        bashio::log.warning "gh credentials exist but were rejected (expired or revoked token?)"
        bashio::log.info "Re-run 'github-setup' to sign in again"
    fi

    # Authentication alone does not make `git push` work; the credential helper
    # is a separate step and is the usual reason a push unexpectedly prompts
    if git config --global --get-regexp '^credential\..*\.helper$' 2>/dev/null | grep -q 'gh auth'; then
        bashio::log.info "git credential helper: gh ✓"
    else
        bashio::log.warning "git credential helper not configured - 'git push' may prompt"
        bashio::log.info "Fix with: gh auth setup-git"
    fi

    local git_name git_email
    git_name=$(git config --global user.name 2>/dev/null)
    git_email=$(git config --global user.email 2>/dev/null)
    if [ -n "$git_name" ] && [ -n "$git_email" ]; then
        bashio::log.info "Commit identity: ${git_name} <${git_email}> ✓"
    else
        bashio::log.warning "No commit identity set - git will refuse to commit"
        bashio::log.info "Set git_user_name and git_user_email in the add-on configuration"
    fi
}

check_network_connectivity() {
    bashio::log.info "=== Network Connectivity Check ==="

    # Check DNS resolution first
    if host registry.npmjs.org >/dev/null 2>&1 || nslookup registry.npmjs.org >/dev/null 2>&1; then
        bashio::log.info "DNS resolution working ✓"
    else
        bashio::log.error "DNS resolution failing - check network configuration"
        bashio::log.info "Try setting custom DNS servers (e.g., 8.8.8.8, 1.1.1.1)"
    fi

    # Try to reach npm registry
    if curl -s --head --connect-timeout 10 --max-time 15 https://registry.npmjs.org > /dev/null; then
        bashio::log.info "Can reach npm registry ✓"
    else
        bashio::log.warning "Cannot reach npm registry - this may affect Claude CLI installation"
        bashio::log.info "This could be due to:"
        bashio::log.info "  - Network proxy/firewall blocking access"
        bashio::log.info "  - DNS resolution issues"
        bashio::log.info "  - Slow network connection (try increasing timeout)"
    fi

    # Try to reach GitHub Container Registry
    if curl -s --head --connect-timeout 10 --max-time 15 https://ghcr.io > /dev/null; then
        bashio::log.info "Can reach GitHub Container Registry ✓"
    else
        bashio::log.error "Cannot reach GitHub Container Registry (ghcr.io)"
        bashio::log.info "This is likely the cause of installation failures"
        bashio::log.info "Possible solutions:"
        bashio::log.info "  1. Check if your network blocks ghcr.io"
        bashio::log.info "  2. Try using a VPN or different network"
        bashio::log.info "  3. Check VM network adapter settings"
    fi

    # Try to reach Anthropic API
    if curl -s --head --connect-timeout 10 --max-time 15 https://api.anthropic.com > /dev/null; then
        bashio::log.info "Can reach Anthropic API ✓"
    else
        bashio::log.warning "Cannot reach Anthropic API - this may affect Claude functionality"
    fi

    # Try to reach the GitHub API
    if curl -s --head --connect-timeout 10 --max-time 15 https://api.github.com > /dev/null; then
        bashio::log.info "Can reach GitHub API ✓"
    else
        bashio::log.warning "Cannot reach GitHub API - gh commands will fail"
    fi
}

run_diagnostics() {
    bashio::log.info "========================================="
    bashio::log.info "Claude Terminal Add-on Health Check"
    bashio::log.info "========================================="

    local errors=0

    check_system_resources || ((errors++))
    check_directory_permissions || ((errors++))
    check_node_installation || ((errors++))
    check_claude_cli || ((errors++))
    check_github_cli || ((errors++))
    check_network_connectivity || ((errors++))

    bashio::log.info "========================================="

    if [ "$errors" -eq 0 ]; then
        bashio::log.info "✅ All checks passed successfully!"
    else
        bashio::log.error "❌ $errors check(s) failed"
        bashio::log.info "Please review the errors above"

        # Provide VirtualBox-specific advice if relevant
        if [ -f /proc/modules ] && grep -q vboxguest /proc/modules; then
            bashio::log.info ""
            bashio::log.info "=== VirtualBox Environment Detected ==="
            bashio::log.warning "VirtualBox users commonly experience network issues"
            bashio::log.info ""
            bashio::log.info "Required VM settings:"
            bashio::log.info "  • Memory: At least 2GB RAM (4GB recommended)"
            bashio::log.info "  • Storage: At least 8GB disk space"
            bashio::log.info "  • VirtualBox Guest Additions: MUST be installed"
            bashio::log.info ""
            bashio::log.info "Network adapter configuration:"
            bashio::log.info "  • Recommended: Bridged Adapter mode"
            bashio::log.info "  • Alternative: NAT with port forwarding"
            bashio::log.info "  • Ensure 'Cable Connected' is checked"
            bashio::log.info ""
            bashio::log.info "If installation fails with network timeout:"
            bashio::log.info "  1. Try changing VM network adapter to Bridged mode"
            bashio::log.info "  2. Restart the VM after network changes"
            bashio::log.info "  3. Check if your host firewall blocks container registries"
            bashio::log.info "  4. Try installation during off-peak hours (network congestion)"
            bashio::log.info "  5. Consider using Home Assistant on bare metal or Docker instead"
        fi

        # Check for Proxmox environment
        if [ -f /proc/cpuinfo ] && grep -q "QEMU Virtual CPU" /proc/cpuinfo; then
            bashio::log.info ""
            bashio::log.info "=== Virtual Environment Detected (Possibly Proxmox) ==="
            bashio::log.info "If running in Proxmox, ensure:"
            bashio::log.info "  • VM has sufficient resources (2GB+ RAM)"
            bashio::log.info "  • Network device uses VirtIO (recommended)"
            bashio::log.info "  • Firewall rules allow container registry access"
            bashio::log.info "  • DNS is properly configured in the VM"
        fi
    fi

    return $errors
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_diagnostics
fi