#!/bin/bash

# data-gc — report and reclaim space under /data.
#
# /data is included in every Home Assistant backup, and three things grow there
# without bound: uv's wheel cache, uv's managed CPython builds, and the Claude
# Code version store, which gains a directory on every self-update. backup_exclude
# keeps them out of backups, but they still consume the add-on's disk.
#
# Runs inside ttyd/tmux (user-visible) — plain bash, no bashio.

set -o pipefail

TERRACOTTA='\033[38;2;217;119;87m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

human() { du -sh "$1" 2>/dev/null | cut -f1; }

report() {
    echo ""
    echo -e "  ${TERRACOTTA}/data usage${NC}"
    echo ""
    printf "    %-42s %s\n" "total" "$(human /data)"
    echo ""
    local p
    for p in "/data/.cache/uv" \
             "/data/.local/share/uv/python" \
             "$HOME/.local/share/claude" \
             "$HOME/.claude/downloads" \
             "$HOME/.claude/projects" \
             "/data/.config"; do
        [ -e "$p" ] || continue
        printf "    %-42s %s\n" "${p#/data/}" "$(human "$p")"
    done
    echo ""
    echo -e "  ${DIM}Reclaimable items are listed above; run 'data-gc clean' to prune${NC}"
    echo -e "  ${DIM}caches and superseded Claude versions. Credentials and session${NC}"
    echo -e "  ${DIM}history are never touched.${NC}"
    echo ""
}

clean() {
    echo ""
    echo -e "  ${TERRACOTTA}Reclaiming space${NC}"
    echo ""
    local before after
    before=$(du -sm /data 2>/dev/null | cut -f1)

    if command -v uv >/dev/null 2>&1; then
        echo -e "    ${WHITE}uv cache${NC}"
        uv cache prune 2>&1 | sed 's/^/      /' || true
    fi

    # Keep the version the symlink points at; drop everything superseded.
    local store="$HOME/.local/share/claude/versions"
    if [ -d "$store" ]; then
        local keep
        keep=$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null)
        echo -e "    ${WHITE}superseded Claude versions${NC}"
        local v
        for v in "$store"/*; do
            [ -e "$v" ] || continue
            case "$keep" in "$v"*) continue ;; esac
            echo "      removing $(basename "$v")"
            rm -rf "$v"
        done
    fi

    # Installer scratch is pure download cache.
    if [ -d "$HOME/.claude/downloads" ]; then
        echo -e "    ${WHITE}installer downloads${NC}"
        rm -rf "${HOME:?}/.claude/downloads"/* 2>/dev/null || true
    fi

    after=$(du -sm /data 2>/dev/null | cut -f1)
    echo ""
    echo -e "  ${WHITE}${before}MB -> ${after}MB${NC}  ${DIM}(reclaimed $(( before - after ))MB)${NC}"
    echo ""
}

case "${1:-report}" in
    report|"")  report ;;
    clean)      clean; report ;;
    help|-h|--help)
        echo "Usage: data-gc [report|clean]"
        echo "  report  show what is using space under /data (default)"
        echo "  clean   prune uv caches, superseded Claude versions and downloads"
        ;;
    *) echo "Unknown command '$1' (try: data-gc help)" >&2; exit 1 ;;
esac
