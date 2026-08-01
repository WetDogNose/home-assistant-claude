#!/bin/bash

# ha-git-backups — Automated git configuration backup & time-machine rollback
# Usage: ha-git-backups [status|commit "<message>"|rollback [--yes]]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-git-backups — Git Configuration Time-Machine for Home Assistant

Usage:
  ha-git-backups status                  Check git status of /config
  ha-git-backups commit "<message>"      Commit current /config state
  ha-git-backups rollback [--yes]        Roll back /config to the previous commit

Rollback discards the newest commit AND any uncommitted changes under /config.
It asks for confirmation; pass --yes to skip the prompt in a script.

Examples:
  ha-git-backups status
  ha-git-backups commit "Updated living room lighting automation"
  ha-git-backups rollback
EOF
}

# Help must work outside the add-on too, so answer it before touching /config.
case "${1:-}" in
    -h|--help|"") show_help; exit 0 ;;
esac

CONFIG_DIR="${HA_CONFIG_DIR:-/config}"

if ! cd "$CONFIG_DIR" 2>/dev/null; then
    echo "Error: ${CONFIG_DIR} is not accessible." >&2
    echo "ha-git-backups must be run inside the Home Assistant add-on environment." >&2
    exit 1
fi

init_git() {
    if [ ! -d ".git" ]; then
        echo "Initializing git repository in $(pwd)..."
        git init
        # secrets.yaml holds every credential in the instance and
        # known_devices.yaml holds device MACs. `commit` runs `git add -A`, so
        # anything not listed here is written into git history -- which then
        # rides along in Home Assistant backups and in any remote this repo is
        # ever pushed to.
        cat << 'GITIGNORE' > .gitignore
*.log
*.log.*
*.db
*.db-shm
*.db-wal
.storage/
__pycache__/
secrets.yaml
known_devices.yaml
ip_bans.yaml
*.key
*.pem
.cloud/
tts/
deps/
GITIGNORE
        git add .gitignore
        git commit -m "Initial commit of ${CONFIG_DIR}" || true
    fi
}

# git refuses to commit without an identity, and the add-on only sets one when
# git_user_name / git_user_email are configured. Fall back to a local identity
# so `commit` doesn't fail with an error that looks unrelated to backups.
ensure_identity() {
    git config user.email >/dev/null 2>&1 || git config user.email "claude-terminal@local"
    git config user.name  >/dev/null 2>&1 || git config user.name  "Claude Terminal"
}

cmd_status() {
    init_git
    echo "=== Home Assistant ${CONFIG_DIR} Git Status ==="
    git status -s
}

cmd_commit() {
    init_git
    ensure_identity
    local msg="${1:-Config backup update}"
    git add -A
    if git diff --cached --quiet; then
        echo "No changes to commit."
        return 0
    fi
    git commit -m "$msg"
    echo "Config successfully committed: '$msg'"
}

cmd_rollback() {
    init_git
    ensure_identity

    # `git reset --hard HEAD~1` on a repo with a single commit fails, and with
    # no parent there is nothing to roll back to. Say so instead of erroring.
    if ! git rev-parse --verify --quiet HEAD~1 >/dev/null; then
        echo "Error: no previous commit to roll back to." >&2
        echo "Run 'ha-git-backups commit \"...\"' at least twice first." >&2
        exit 1
    fi

    local target
    target=$(git log -n 1 --oneline HEAD~1)

    echo "⚠️  Rollback will PERMANENTLY discard:"
    echo "    - the newest commit: $(git log -n 1 --oneline HEAD)"
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "    - ALL uncommitted changes under ${CONFIG_DIR}:"
        git status -s | sed 's/^/        /'
    fi
    echo "    Restoring: ${target}"
    echo ""

    if [ "${1:-}" != "--yes" ]; then
        # Never destroy a user's Home Assistant configuration on a bare
        # subcommand -- the previous version reset --hard with no prompt at all.
        local reply=""
        read -r -p "Type 'rollback' to confirm: " reply || reply=""
        if [ "$reply" != "rollback" ]; then
            echo "Aborted; nothing was changed."
            exit 1
        fi
    fi

    git reset --hard HEAD~1
    echo "Rollback completed. Restored state:"
    git log -n 1 --oneline
}

case "${1:-}" in
    status)
        cmd_status
        ;;
    commit)
        cmd_commit "${2:-}"
        ;;
    rollback)
        cmd_rollback "${2:-}"
        ;;
    *)
        show_help
        ;;
esac
