#!/bin/bash

# github-setup — sign in to GitHub and make `git push` work from this terminal.
#
# Two separate things must be true before Claude can manage GitHub from here,
# and only the first is obvious:
#   1. gh is authenticated                (gh auth login)
#   2. git uses gh as its credential helper (gh auth setup-git)
# Skipping step 2 is the usual cause of a push that fails asking for a password
# long after the login appeared to succeed, so this script always does both.
#
# Credentials are written to $XDG_CONFIG_HOME/gh (i.e. /data/.config/gh), which
# is persistent storage — this is a one-time setup that survives restarts and
# add-on updates.
#
# Runs inside ttyd/tmux (user-visible) — plain bash, no bashio.

set -o pipefail

TERRACOTTA='\033[38;2;217;119;87m'
WHITE='\033[1;37m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) is not installed in this image." >&2
    exit 1
fi

echo ""
echo -e "  ${TERRACOTTA}GitHub setup${NC}"
echo ""

# --- 1. Authenticate ---------------------------------------------------------

if gh auth status >/dev/null 2>&1; then
    echo -e "  ${WHITE}Already signed in.${NC}"
    gh auth status 2>&1 | sed 's/^/  /'
    echo ""
    read -r -p "  Sign in again (e.g. as a different account)? [y/N] " again
    echo ""
else
    again="y"
    echo -e "  You'll get a short URL and an ${WHITE}8-character code${NC}."
    echo -e "  ${DIM}Open the URL on any device, enter the code, and authorize.${NC}"
    echo ""
    echo -e "  ${YELLOW}Scopes:${NC} accept the defaults unless you need more."
    echo -e "  ${DIM}Avoid the 'workflow' scope unless you truly need it — it${NC}"
    echo -e "  ${DIM}permits rewriting CI, which is code execution in Actions.${NC}"
    echo -e "  ${DIM}For tighter control, create a fine-grained token limited to${NC}"
    echo -e "  ${DIM}specific repositories and use: gh auth login --with-token${NC}"
    echo ""
fi

if [[ "$again" =~ ^[Yy]$ ]]; then
    if ! gh auth login; then
        echo ""
        echo "  Login failed or was cancelled. Nothing was changed." >&2
        exit 1
    fi
fi

# --- 2. Teach git to use gh for HTTPS pushes ---------------------------------

echo ""
if gh auth setup-git; then
    echo -e "  ${WHITE}git credential helper configured${NC} — HTTPS pushes will use gh."
else
    echo "  Warning: 'gh auth setup-git' failed; git push may prompt for credentials." >&2
fi

# --- 3. Commit identity ------------------------------------------------------

git_name=$(git config --global user.name || true)
git_email=$(git config --global user.email || true)

echo ""
if [ -n "$git_name" ] && [ -n "$git_email" ]; then
    echo -e "  Commits will be authored as ${WHITE}${git_name} <${git_email}>${NC}"
else
    echo -e "  ${YELLOW}No commit identity set${NC} — git will refuse to commit."
    echo -e "  ${DIM}Set 'git_user_name' and 'git_user_email' in the add-on${NC}"
    echo -e "  ${DIM}configuration (they are reapplied on every restart), or run:${NC}"
    echo ""
    echo -e "    git config --global user.name  \"Your Name\""
    echo -e "    git config --global user.email \"you@example.com\""
fi

# --- 4. Where the token lives ------------------------------------------------

echo ""
echo -e "  ${DIM}Your token is stored at /data/.config/gh/hosts.yml. Alpine has no${NC}"
echo -e "  ${DIM}keyring, so it is plaintext, and /data is included in Home${NC}"
echo -e "  ${DIM}Assistant backups — treat those backups as secrets.${NC}"
echo -e "  ${DIM}Sign out at any time with: gh auth logout${NC}"
echo ""
