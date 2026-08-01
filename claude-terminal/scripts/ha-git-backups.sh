#!/bin/bash

# ha-git-backups — Automated git configuration backup & 1-click time-machine rollback
# Usage: ha-git-backups [commit "<message>"|rollback|status]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-git-backups — Git Configuration Time-Machine for Home Assistant

Usage:
  ha-git-backups status                  Check git status of /config
  ha-git-backups commit "<message>"      Commit current /config state
  ha-git-backups rollback                Roll back /config to previous commit

Examples:
  ha-git-backups status
  ha-git-backups commit "Updated living room lighting automation"
  ha-git-backups rollback
EOF
}

cd /config 2>/dev/null || cd /tmp

init_git() {
    if [ ! -d ".git" ]; then
        echo "Initializing git repository in $(pwd)..."
        git init
        cat << 'GITIGNORE' > .gitignore
*.log
*.db
*.db-shm
*.db-wal
.storage/
__pycache__/
GITIGNORE
        git add .gitignore
        git commit -m "Initial commit of /config" || true
    fi
}

cmd_status() {
    init_git
    echo "=== Home Assistant /config Git Status ==="
    git status -s
}

cmd_commit() {
    init_git
    local msg="${1:-Config backup update}"
    git add -A
    if git commit -m "$msg"; then
        echo "Config successfully committed: '$msg'"
    else
        echo "No changes to commit."
    fi
}

cmd_rollback() {
    init_git
    echo "⚠️ Rolling back /config to previous commit..."
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
        cmd_rollback
        ;;
    -h|--help)
        show_help
        ;;
    *)
        show_help
        ;;
esac
