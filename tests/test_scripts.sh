#!/bin/bash

# Test suite for Claude Terminal shell scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../claude-terminal/scripts" && pwd)"
PASSED=0
FAILED=0

assert_exit_code() {
    local expected="$1"
    shift
    local cmd=("$@")

    set +e
    "${cmd[@]}" >/dev/null 2>&1
    local code=$?
    set -e

    if [ "$code" -eq "$expected" ]; then
        PASSED=$((PASSED + 1))
        echo "  [PASS] ${cmd[*]} returned exit code $expected"
    else
        FAILED=$((FAILED + 1))
        echo "  [FAIL] ${cmd[*]} returned $code, expected $expected"
    fi
}

echo "=== Running Shell Script Unit Tests ==="

echo "1. Testing ha-validate.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-validate.sh" --help
SUPERVISOR_TOKEN="" assert_exit_code 1 "$SCRIPT_DIR/ha-validate.sh"

echo "2. Testing ha-snapshot.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-snapshot.sh" --help
SUPERVISOR_TOKEN="" assert_exit_code 1 "$SCRIPT_DIR/ha-snapshot.sh" camera.front_door

echo "3. Testing ha-tts.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-tts.sh" --help
SUPERVISOR_TOKEN="" assert_exit_code 1 "$SCRIPT_DIR/ha-tts.sh" "Test message"

echo "4. Testing ha-scaffold.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-scaffold.sh" --help

# Test scaffold generation in temp directory
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# NOT wrapped in ( ... ). A subshell gets its own copy of PASSED/FAILED, so
# every increment below was discarded when it exited: 11 of the suite's
# assertions could print [FAIL] and still leave the final count at zero, and
# the suite exited 0 with failures on screen.
DOMAIN="test_solar"
TARGET="$TEST_DIR/custom_components/$DOMAIN"

mkdir -p "$TEST_DIR/custom_components"
sed "s|/config/custom_components|$TEST_DIR/custom_components|g" "$SCRIPT_DIR/ha-scaffold.sh" > "$TEST_DIR/run_scaffold.sh"
chmod +x "$TEST_DIR/run_scaffold.sh"

"$TEST_DIR/run_scaffold.sh" "$DOMAIN" "Test Solar" "Solar testing integration" >/dev/null

for f in manifest.json const.py __init__.py config_flow.py sensor.py strings.json README.md; do
    if [ -f "$TARGET/$f" ]; then
        echo "  [PASS] ha-scaffold generated $f"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] ha-scaffold missing $f"
        FAILED=$((FAILED + 1))
    fi
done

# Verify PyScript scaffolding
mkdir -p "$TEST_DIR/pyscript"
sed "s|/config/pyscript|$TEST_DIR/pyscript|g" "$SCRIPT_DIR/ha-scaffold.sh" > "$TEST_DIR/run_pyscript.sh"
chmod +x "$TEST_DIR/run_pyscript.sh"
"$TEST_DIR/run_pyscript.sh" pyscript test_hvac "Test HVAC handler" >/dev/null
if [ -f "$TEST_DIR/pyscript/test_hvac.py" ]; then
    echo "  [PASS] ha-scaffold pyscript generated test_hvac.py"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] ha-scaffold pyscript failed to generate test_hvac.py"
    FAILED=$((FAILED + 1))
fi

echo "5. Testing claude-cron.sh"
assert_exit_code 0 "$SCRIPT_DIR/claude-cron.sh" --help

CRON_TEST_DIR=$(mktemp -d)
export CRON_FILE="$CRON_TEST_DIR/claude-cron.json"

"$SCRIPT_DIR/claude-cron.sh" add "30" "Test prompt" >/dev/null
if grep -q "Test prompt" "$CRON_FILE"; then
    echo "  [PASS] claude-cron add succeeded"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-cron add failed"
    FAILED=$((FAILED + 1))
fi

if "$SCRIPT_DIR/claude-cron.sh" list | grep -q "Test prompt"; then
    echo "  [PASS] claude-cron list succeeded"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-cron list failed"
    FAILED=$((FAILED + 1))
fi

"$SCRIPT_DIR/claude-cron.sh" remove 1 >/dev/null
if ! grep -q "Test prompt" "$CRON_FILE"; then
    echo "  [PASS] claude-cron remove succeeded"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-cron remove failed"
    FAILED=$((FAILED + 1))
fi

rm -rf "$CRON_TEST_DIR"
unset CRON_FILE

echo "6. Testing ha-diagnose.sh"
DIAGNOSE_OUTPUT=$("$SCRIPT_DIR/ha-diagnose.sh")
if echo "$DIAGNOSE_OUTPUT" | grep -q "Diagnostic Report"; then
    echo "  [PASS] ha-diagnose output header valid"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] ha-diagnose output header invalid"
    FAILED=$((FAILED + 1))
fi

echo "7. Testing ha-dashboard.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-dashboard.sh" --help
SUPERVISOR_TOKEN="" assert_exit_code 1 "$SCRIPT_DIR/ha-dashboard.sh" light

echo "8. Testing ha-mesh.sh"
SUPERVISOR_TOKEN="" assert_exit_code 1 "$SCRIPT_DIR/ha-mesh.sh"

echo "9. Testing ha-assist.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-assist.sh" --help
SUPERVISOR_TOKEN="" assert_exit_code 1 "$SCRIPT_DIR/ha-assist.sh" "hello"

echo "10. Testing ha-memory.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-memory.sh" --help
SUPERVISOR_TOKEN="" assert_exit_code 1 "$SCRIPT_DIR/ha-memory.sh" light.hallway

echo "11. Testing claude-bot.sh"
assert_exit_code 0 "$SCRIPT_DIR/claude-bot.sh" --help

BOT_TEST_DIR=$(mktemp -d)
export BOT_CONFIG="$BOT_TEST_DIR/claude-bot-config.json"
assert_exit_code 0 "$SCRIPT_DIR/claude-bot.sh" status
assert_exit_code 0 "$SCRIPT_DIR/claude-bot.sh" setup
rm -rf "$BOT_TEST_DIR"
unset BOT_CONFIG

echo "12. Testing ha-git-backups.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-git-backups.sh" --help

echo "13. Testing shipped blueprints parse as YAML"
BLUEPRINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../claude-terminal/blueprints" && pwd)"

# 0 = valid, 1 = invalid, 2 = no YAML parser available.
#
# Distinguishing 2 matters: reporting a missing PyYAML as "not valid YAML"
# sends you looking for a syntax error that isn't there.
yaml_parses() {
    local f="$1"
    if python3 -c "import yaml" 2>/dev/null; then
        # Home Assistant blueprints use the custom !input tag, which safe_load
        # rejects; register it so this tests YAML validity, not tag support.
        python3 -c "
import sys, yaml
class L(yaml.SafeLoader): pass
L.add_constructor('!input', lambda loader, node: loader.construct_scalar(node))
yaml.load(open(sys.argv[1]), Loader=L)
" "$f" 2>/dev/null || return 1
        return 0
    fi
    if command -v ruby >/dev/null 2>&1; then
        ruby -ryaml -e "YAML.load_file(ARGV[0])" "$f" >/dev/null 2>&1 || return 1
        return 0
    fi
    return 2
}

for bp in "$BLUEPRINT_DIR"/*.yaml; do
    rc=0
    yaml_parses "$bp" || rc=$?
    case "$rc" in
        0)
            echo "  [PASS] $(basename "$bp") is valid YAML"
            PASSED=$((PASSED + 1))
            ;;
        1)
            echo "  [FAIL] $(basename "$bp") is not valid YAML"
            FAILED=$((FAILED + 1))
            ;;
        *)
            echo "  [FAIL] $(basename "$bp") could not be checked: no YAML parser found (pip install pyyaml)"
            FAILED=$((FAILED + 1))
            ;;
    esac
done

echo "14. Testing Automation API callers agree with the server routes"
# claude-bot and the blueprint both used /api/query, which the server has never
# routed; every call 404'd. Keep the paths in step. Comments are stripped so a
# path named only in prose doesn't count as a call.
API_SERVER="$SCRIPT_DIR/claude-api-server.py"
for caller in "$SCRIPT_DIR/claude-bot.sh" "$BLUEPRINT_DIR/claude_automation_query.yaml"; do
    bad=$(sed 's/#.*//' "$caller" | grep -oE '/api/[a-z]+' | sort -u | while read -r path; do
        grep -q "\"${path}\"" "$API_SERVER" || echo "$path"
    done)
    if [ -z "$bad" ]; then
        echo "  [PASS] $(basename "$caller") uses only routed API paths"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] $(basename "$caller") calls unrouted path(s): $bad"
        FAILED=$((FAILED + 1))
    fi
done

echo "15. Testing bundled Claude Code skills"
SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../claude-terminal/skills" && pwd)"
RUN_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../claude-terminal" && pwd)/run.sh"
DOCKERFILE="$(dirname "$RUN_SH")/Dockerfile"

# A skill is inert without frontmatter, and Claude matches on `name`, so a name
# that disagrees with the directory produces a skill that can be listed but not
# reliably invoked.
for skill_dir in "$SKILLS_DIR"/*/; do
    skill_name=$(basename "$skill_dir")
    skill_file="${skill_dir}SKILL.md"

    if [ ! -f "$skill_file" ]; then
        echo "  [FAIL] $skill_name has no SKILL.md"
        FAILED=$((FAILED + 1))
        continue
    fi

    if [ "$(head -n 1 "$skill_file")" != "---" ] \
        || ! grep -q "^name: ${skill_name}$" "$skill_file" \
        || ! grep -q '^description: .' "$skill_file"; then
        echo "  [FAIL] $skill_name has malformed frontmatter (need ---, name: $skill_name, description:)"
        FAILED=$((FAILED + 1))
        continue
    fi

    echo "  [PASS] $skill_name frontmatter is well formed"
    PASSED=$((PASSED + 1))
done

# The skills exist to tell Claude which commands are available, so a skill
# naming a command the add-on does not install is worse than no skill at all:
# it sends Claude confidently at a command that is not there. Keep the two in
# step by checking every ha-/claude-/esphome-/persist- token in a skill against
# what setup_commands actually puts in /usr/local/bin.
INSTALLED_COMMANDS=$(grep -oE '"[a-z0-9-]+:/opt/scripts/' "$RUN_SH" | sed 's/"//; s/:.*//')
SKILL_NAMES=$(basename -a "$SKILLS_DIR"/*/)
KNOWN_NAMES=$(printf '%s\n%s\n' "$INSTALLED_COMMANDS" "$SKILL_NAMES" | sort -u)

for skill_dir in "$SKILLS_DIR"/*/; do
    skill_name=$(basename "$skill_dir")
    [ -f "${skill_dir}SKILL.md" ] || continue

    # A token preceded by "/" is a path component (/config/claude-snapshots),
    # not a command being invoked, so it is excluded rather than reported as a
    # command that does not exist.
    unknown=$(grep -oE '(^|[^/[:alnum:]_-])(ha|claude|esphome|persist)-[a-z-]+[a-z]' "${skill_dir}SKILL.md" \
        | sed -E 's/^[^a-z]+//' | sort -u | while read -r token; do
            echo "$KNOWN_NAMES" | grep -qx "$token" || echo "$token"
        done)

    if [ -z "$unknown" ]; then
        echo "  [PASS] $skill_name references only installed commands"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] $skill_name references unknown command(s): $(echo "$unknown" | tr '\n' ' ')"
        FAILED=$((FAILED + 1))
    fi
done

# Shipping the skills without wiring them in is the silent failure this catches:
# the files are in the repo, the image copies nothing, and Claude never sees them.
if grep -q '^COPY skills/ /opt/skills/$' "$DOCKERFILE"; then
    echo "  [PASS] Dockerfile copies skills/ into the image"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] Dockerfile does not COPY skills/ into /opt/skills/"
    FAILED=$((FAILED + 1))
fi

if grep -q '^    install_skills$' "$RUN_SH"; then
    echo "  [PASS] run.sh main() installs skills at boot"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] run.sh main() does not call install_skills"
    FAILED=$((FAILED + 1))
fi

echo "16. Testing blueprint loop guards and install-once behaviour"

# An automation built from this blueprint can act on Home Assistant, and its
# actions produce events -- so a trigger on HA's own output can re-fire on the
# previous run's consequences. mode: single bounds the pile-up and
# max_exceeded: silent stops the drop from logging a warning, which would
# itself be an event such a trigger could fire on.
BP="$BLUEPRINT_DIR/claude_automation_query.yaml"
for key in '^mode: single$' '^max_exceeded: silent$'; do
    if grep -qE "$key" "$BP"; then
        echo "  [PASS] blueprint declares ${key//[\^$]/}"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] blueprint is missing ${key//[\^$]/} (feedback-loop guard)"
        FAILED=$((FAILED + 1))
    fi
done

# The blueprint used to be re-copied into /config on every start, which meant a
# user could not delete it (it came back) and could not harden it (edits were
# reverted). Guard the shape of the fix, not just its presence.
if grep -q '^install_blueprint()' "$RUN_SH" && ! grep -q 'sync_blueprints' "$RUN_SH"; then
    echo "  [PASS] run.sh installs the blueprint via install_blueprint"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] run.sh should define install_blueprint and no longer reference sync_blueprints"
    FAILED=$((FAILED + 1))
fi

if grep -q 'blueprint-baseline' "$RUN_SH"; then
    echo "  [PASS] blueprint install records a baseline so edits and deletions stick"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] run.sh does not record a blueprint baseline; edits/deletions can be clobbered"
    FAILED=$((FAILED + 1))
fi

echo "17. Testing sign-in URL reassembly"

# Claude Code hard-wraps the sign-in URL to the terminal width, so the pane
# holds several real lines rather than one soft-wrapped one. The notification
# used to grep the first of them and send a URL missing its PKCE tail: a link
# that opens and then fails to authorize. These cases pin the reassembly.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/login-url-lib.sh"

LOGIN_URL='https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Aprofile+user%3Ainference&code_challenge=Ky7bV9pQ2mNx4LrT8sZaWc1dEfGhIjKlMnOpQrStUvW&code_challenge_method=S256&state=Ab3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4yZ5aB6c'

# NOT fed from a pipe: a piped call runs in a subshell, and every PASSED /
# FAILED increment below it is discarded when that subshell exits.
assert_extracts() {
    local name="$1" expected="$2" text="$3" actual
    actual=$(printf '%s\n' "$text" | login_url_from_text)
    if [ "$actual" = "$expected" ]; then
        echo "  [PASS] login URL reassembly: $name"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] login URL reassembly: $name"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

# Every width the add-on realistically renders at, plus the un-wrapped case.
for width in 40 60 80 100 120; do
    assert_extracts "hard-wrapped at $width columns" "$LOGIN_URL" \
        "$(printf '%s' "$LOGIN_URL" | fold -w "$width")"
done

LOGIN_SCREEN=$(
    printf '%s\n\n' "Browser did not open? Use the url below to sign in (c to copy)"
    printf '%s' "$LOGIN_URL" | fold -w 80
    printf '\n\n%s\n' "Paste code here if prompted > "
)
assert_extracts "surrounded by the rest of the login screen" "$LOGIN_URL" "$LOGIN_SCREEN"

# capture-pane -J preserves trailing spaces, so the joiner has to trim.
assert_extracts "wrapped with trailing whitespace" "$LOGIN_URL" \
    "$(printf '%s' "$LOGIN_URL" | fold -w 80 | sed 's/$/   /')"

# A URL that already ended mid-line was never wrapped, so the word on the line
# below it is a word and not the rest of the URL.
assert_extracts "printed inline on one line" "$LOGIN_URL" \
    "$(printf 'If the browser did not open, visit: %s\ndone\n' "$LOGIN_URL")"

# A stale URL higher up the scrollback must not be glued to the current one.
SCROLLBACK=$(
    echo "https://claude.ai/oauth/authorize?code=true&state=OLDOLDOLDOLDOLDOLDOLD"
    printf '%s' "$LOGIN_URL" | fold -w 60
)
assert_extracts "a second URL replaces the first" "$LOGIN_URL" "$SCROLLBACK"

assert_extracts "no URL present" "" "no URLs on screen at all"

# The completeness check is what keeps a broken link out of the notification.
for url in "$LOGIN_URL" "${LOGIN_URL}&orgUUID=1234"; do
    if login_url_is_complete "$url"; then
        echo "  [PASS] login_url_is_complete accepts a whole sign-in URL"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] login_url_is_complete rejected a whole sign-in URL: $url"
        FAILED=$((FAILED + 1))
    fi
done

for url in "${LOGIN_URL:0:80}" "${LOGIN_URL:0:300}" "https://code.claude.com/docs/en/overview" ""; do
    if login_url_is_complete "$url"; then
        echo "  [FAIL] login_url_is_complete accepted an unusable URL: $url"
        FAILED=$((FAILED + 1))
    else
        echo "  [PASS] login_url_is_complete rejects '${url:0:40}'"
        PASSED=$((PASSED + 1))
    fi
done

# Both consumers must go through the library; a local grep here is the bug.
for consumer in claude-login-url.sh claude-login-notifier.sh; do
    if grep -q 'login-url-lib.sh' "$SCRIPT_DIR/$consumer" \
        && ! grep -q 'grep -oE "https://' "$SCRIPT_DIR/$consumer"; then
        echo "  [PASS] $consumer reassembles the URL via login-url-lib.sh"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] $consumer does not use login-url-lib.sh to reassemble the URL"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=== Shell Script Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
