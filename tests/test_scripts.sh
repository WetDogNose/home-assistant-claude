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

echo "18. Testing state-lib.sh locking and atomic updates"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/state-lib.sh"

STATE_TEST_DIR=$(mktemp -d)
LOCK_DOC="$STATE_TEST_DIR/doc.json"

json_update "$LOCK_DOC" '{"items": []}' --arg v "first" '.items += [$v]' 
if [ "$(json_read "$LOCK_DOC" '{"items": []}' '.items | length')" = "1" ]; then
    echo "  [PASS] json_update seeds and appends"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] json_update did not append to a fresh document"
    FAILED=$((FAILED + 1))
fi

# The signature mirrors jq: options first, filter LAST. Passing them the other
# way round used to run jq with "--argjson" as the filter, which failed, fell
# back to the default document, and made every existing record look missing.
if [ "$(json_read "$LOCK_DOC" '{"items": []}' --arg x 1 '.items[0]')" = "first" ]; then
    echo "  [PASS] json_read takes jq options before the filter"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] json_read mishandles jq options placed before the filter"
    FAILED=$((FAILED + 1))
fi

# A bad filter must leave the document intact rather than truncating it.
json_update "$LOCK_DOC" '{"items": []}' '.items | this is not jq' 2>/dev/null || true
if jq -e . "$LOCK_DOC" >/dev/null 2>&1; then
    echo "  [PASS] a failed json_update leaves the document valid"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] a failed json_update destroyed the document"
    FAILED=$((FAILED + 1))
fi

# _state_mtime must emit digits or nothing -- never prose.
#
# GNU's `stat -f` is --file-system: it IGNORES the format string and prints a
# multi-line report starting `  File: "..."`. Fed into `$(( now - mtime ))` that
# blob is parsed as an arithmetic expression, so bash reads `File` as a variable
# name: an "unbound variable" abort under `set -u` -- which killed callers
# outright and lost their writes -- and a silent syntax error otherwise, which
# skips the stale-lock check for ever, so a lock left by a killed daemon is
# never broken and every later caller times out.
#
# This passed on macOS (where `stat -c` fails and the BSD `-f` really does mean
# mtime) and failed on Linux, which is what CI runs.
for probe in "$STATE_TEST_DIR" /nonexistent-path-for-a-test; do
    probe_mtime=$(_state_mtime "$probe")
    case "$probe_mtime" in
        ''|*[!0-9]*)
            if [ -z "$probe_mtime" ] && [ ! -e "$probe" ]; then
                echo "  [PASS] _state_mtime returns nothing for a missing path"
                PASSED=$((PASSED + 1))
            else
                echo "  [FAIL] _state_mtime returned non-numeric output: ${probe_mtime%%$'\n'*}"
                FAILED=$((FAILED + 1))
            fi
            ;;
        *)
            echo "  [PASS] _state_mtime returns a bare epoch for an existing path"
            PASSED=$((PASSED + 1))
            ;;
    esac
done

# The race this library exists to close: concurrent read-modify-writes.
# Before the lock, parallel writers lost updates silently -- adding a scheduled
# job while one was running simply discarded the new job.
CONCURRENT_DOC="$STATE_TEST_DIR/concurrent.json"
for i in $(seq 1 12); do
    ( json_update "$CONCURRENT_DOC" '{"items": []}' --argjson n "$i" '.items += [$n]' || true ) &
done
wait
concurrent_count=$(json_read "$CONCURRENT_DOC" '{"items": []}' '.items | length')
if [ "$concurrent_count" = "12" ]; then
    echo "  [PASS] 12 concurrent json_updates all landed"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] concurrent json_updates lost writes (kept ${concurrent_count} of 12)"
    FAILED=$((FAILED + 1))
fi

rm -rf "$STATE_TEST_DIR"

echo "19. Testing ha-entity.sh"
assert_exit_code 0 "$SCRIPT_DIR/ha-entity.sh" --help
SUPERVISOR_TOKEN="" assert_exit_code 1 "$SCRIPT_DIR/ha-entity.sh" sync

ENTITY_TEST_DIR=$(mktemp -d)
export CLAUDE_STATE_FILE="$ENTITY_TEST_DIR/state.json"

"$SCRIPT_DIR/ha-entity.sh" set busy=true status=running last_source=cron >/dev/null 2>&1 || true
# true/false must be stored as JSON booleans, not the strings "true"/"false":
# the API server and the hooks both read .busy with jq and would otherwise see
# a truthy string where they expect a boolean.
if [ "$(jq -r '.busy | type' "$CLAUDE_STATE_FILE")" = "boolean" ] \
    && [ "$(jq -r '.status' "$CLAUDE_STATE_FILE")" = "running" ]; then
    echo "  [PASS] ha-entity set stores booleans as booleans"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] ha-entity set wrote the wrong types"
    FAILED=$((FAILED + 1))
fi

"$SCRIPT_DIR/ha-entity.sh" set busy=false >/dev/null 2>&1 || true
if [ "$(jq -r '.busy' "$CLAUDE_STATE_FILE")" = "false" ] \
    && [ "$(jq -r '.status' "$CLAUDE_STATE_FILE")" = "running" ]; then
    echo "  [PASS] ha-entity set merges rather than replaces"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] ha-entity set clobbered unrelated keys"
    FAILED=$((FAILED + 1))
fi

assert_exit_code 1 "$SCRIPT_DIR/ha-entity.sh" set notavalidpair
unset CLAUDE_STATE_FILE
rm -rf "$ENTITY_TEST_DIR"

echo "20. Testing claude-hooks.sh"
assert_exit_code 0 "$SCRIPT_DIR/claude-hooks.sh" --help

HOOK_TEST_DIR=$(mktemp -d)
export CLAUDE_HOOKS_SETTINGS="$HOOK_TEST_DIR/settings.json"
export OPTIONS_FILE="$HOOK_TEST_DIR/options.json"
export CLAUDE_HOOK_RUNDIR="$HOOK_TEST_DIR/run"
echo '{"notify_on_completion": true, "enable_ha_entities": true}' > "$OPTIONS_FILE"

# A hook the USER wrote must survive every install and every removal. $HOME is
# /data and persists, so this file is shared between the add-on and its user.
cat > "$CLAUDE_HOOKS_SETTINGS" << 'USERHOOK'
{"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"my-own-script.sh"}]}]}}
USERHOOK

"$SCRIPT_DIR/claude-hooks.sh" install >/dev/null 2>&1 || true
installed=$(jq -r '[.hooks | to_entries[] | .value[].hooks[] | select(.command | startswith("claude-hooks handle")) | .command] | length' "$CLAUDE_HOOKS_SETTINGS")
if [ "$installed" = "4" ]; then
    echo "  [PASS] claude-hooks install wires all four events"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-hooks install wired ${installed} hooks, expected 4"
    FAILED=$((FAILED + 1))
fi

# Installing twice must not stack duplicates: this runs on EVERY boot, so a
# non-idempotent install would grow settings.json without limit.
"$SCRIPT_DIR/claude-hooks.sh" install >/dev/null 2>&1 || true
installed_again=$(jq -r '[.hooks | to_entries[] | .value[].hooks[] | select(.command | startswith("claude-hooks handle")) | .command] | length' "$CLAUDE_HOOKS_SETTINGS")
if [ "$installed_again" = "4" ]; then
    echo "  [PASS] claude-hooks install is idempotent"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-hooks install stacked duplicates (${installed_again} after two runs)"
    FAILED=$((FAILED + 1))
fi

"$SCRIPT_DIR/claude-hooks.sh" remove >/dev/null 2>&1 || true
remaining=$(jq -r '[.hooks.Stop[].hooks[].command] | join(",")' "$CLAUDE_HOOKS_SETTINGS" 2>/dev/null)
if [ "$remaining" = "my-own-script.sh" ] && [ "$(jq -r '.model' "$CLAUDE_HOOKS_SETTINGS")" = "opus" ]; then
    echo "  [PASS] claude-hooks remove leaves the user's own hooks and settings alone"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-hooks remove disturbed the user's settings (left: ${remaining})"
    FAILED=$((FAILED + 1))
fi

# A settings.json that is not valid JSON is the user's file mid-edit. Replacing
# it would silently discard whatever they were writing.
echo '{ this is not json' > "$CLAUDE_HOOKS_SETTINGS"
"$SCRIPT_DIR/claude-hooks.sh" install >/dev/null 2>&1 || true
if grep -q 'this is not json' "$CLAUDE_HOOKS_SETTINGS"; then
    echo "  [PASS] claude-hooks refuses to overwrite an unparseable settings.json"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-hooks overwrote a settings.json it could not parse"
    FAILED=$((FAILED + 1))
fi

# The handler must ALWAYS exit 0. A non-zero hook surfaces as an error inside
# the user's Claude session, so a failed notification would become a visible
# fault in the middle of their work.
hook_rc=0
echo '{"session_id":"t1"}' | "$SCRIPT_DIR/claude-hooks.sh" handle stop --foreground >/dev/null 2>&1 || hook_rc=$?
hook_rc_bad=0
echo '{"broken' | "$SCRIPT_DIR/claude-hooks.sh" handle notification --foreground >/dev/null 2>&1 || hook_rc_bad=$?
if [ "$hook_rc" -eq 0 ] && [ "$hook_rc_bad" -eq 0 ]; then
    echo "  [PASS] the hook handler always exits 0, even on malformed input"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] the hook handler returned non-zero (${hook_rc}/${hook_rc_bad})"
    FAILED=$((FAILED + 1))
fi

# Automation-API and scheduled runs suppress the hooks so they do not notify
# twice for one job.
CLAUDE_TERMINAL_NO_HOOK_NOTIFY=1 CLAUDE_STATE_FILE="$HOOK_TEST_DIR/suppressed.json" \
    bash -c "echo '{\"session_id\":\"t2\"}' | '$SCRIPT_DIR/claude-hooks.sh' handle prompt-submit" >/dev/null 2>&1
if [ ! -f "$HOOK_TEST_DIR/suppressed.json" ]; then
    echo "  [PASS] CLAUDE_TERMINAL_NO_HOOK_NOTIFY suppresses the handler entirely"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] CLAUDE_TERMINAL_NO_HOOK_NOTIFY did not suppress the handler"
    FAILED=$((FAILED + 1))
fi

unset CLAUDE_HOOKS_SETTINGS OPTIONS_FILE CLAUDE_HOOK_RUNDIR
rm -rf "$HOOK_TEST_DIR"

echo "21. Testing claude-usage.sh"
assert_exit_code 0 "$SCRIPT_DIR/claude-usage.sh" --help
assert_exit_code 1 "$SCRIPT_DIR/claude-usage.sh" --days notanumber

USAGE_TEST_DIR=$(mktemp -d)
mkdir -p "$USAGE_TEST_DIR/projects/demo"
usage_today=$(date -u +%Y-%m-%d)
cat > "$USAGE_TEST_DIR/projects/demo/session.jsonl" << USAGEJSON
{"timestamp":"${usage_today}T10:00:00.000Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":2000,"cache_read_input_tokens":18000}}}
{"timestamp":"${usage_today}T10:05:00.000Z","type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":900}},"costUSD":0.0123}
{"type":"user","message":{"content":"no usage here"}}
{"a partial line still being written
USAGEJSON

usage_json=$(CLAUDE_PROJECTS_DIR="$USAGE_TEST_DIR/projects" "$SCRIPT_DIR/claude-usage.sh" --days 2 --json)
if [ "$(printf '%s' "$usage_json" | jq -r '.total.input')" = "110" ] \
    && [ "$(printf '%s' "$usage_json" | jq -r '.total.output')" = "950" ] \
    && [ "$(printf '%s' "$usage_json" | jq -r '.total.messages')" = "2" ]; then
    echo "  [PASS] claude-usage totals tokens across a transcript"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-usage totals are wrong: $(printf '%s' "$usage_json" | jq -c '.total')"
    FAILED=$((FAILED + 1))
fi

# A transcript being appended to right now has a partial final line. Aborting on
# it would make the report fail exactly while Claude is working.
if [ "$(printf '%s' "$usage_json" | jq -r '.total.cache_read')" = "18000" ]; then
    echo "  [PASS] claude-usage skips a partially written line without failing"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-usage mishandled a truncated JSONL line"
    FAILED=$((FAILED + 1))
fi

# Cache reads must stay out of the input figure: they are the cheap half of a
# long session, and folding them in makes a well-cached day look expensive.
if [ "$(printf '%s' "$usage_json" | jq -r '.total.input')" != "18110" ]; then
    echo "  [PASS] claude-usage reports cache reads separately from fresh input"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-usage folded cache reads into input"
    FAILED=$((FAILED + 1))
fi

# No transcripts at all must be a clean empty report, not an error: that is the
# state of a freshly installed add-on.
empty_json=$(CLAUDE_PROJECTS_DIR="$USAGE_TEST_DIR/nothing-here" "$SCRIPT_DIR/claude-usage.sh" --json)
if [ "$(printf '%s' "$empty_json" | jq -r '.total.input')" = "0" ]; then
    echo "  [PASS] claude-usage reports zero when there is nothing to report"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-usage did not handle a missing projects directory"
    FAILED=$((FAILED + 1))
fi

rm -rf "$USAGE_TEST_DIR"

echo "22. Testing claude-session.sh"
assert_exit_code 0 "$SCRIPT_DIR/claude-session.sh" --help
# Without a tmux server there is nothing to list, and saying so beats a stack
# trace from tmux.
assert_exit_code 1 "$SCRIPT_DIR/claude-session.sh" list

echo "23. Testing claude-cron schedule parsing"

# Source the schedule functions on their own.
#
# The extract starts AFTER claude-cron's `. "$LIB"` line and stops before the
# dispatcher at the bottom. Both ends matter: the dispatcher would run a command
# on every source, and the library lookup above it resolves relative to $0 --
# which when sourced is this test script, not claude-cron -- so it would not
# find state-lib.sh and would `exit 1`, killing the whole suite. state-lib.sh is
# already sourced into this shell by section 18, so the functions it provides
# are inherited by the subshells below.
CRON_LIB=$(mktemp)
awk '/^\. "\$LIB"$/ {on = 1; next} /^case "\$\{1:-\}" in$/ {exit} on {print}' \
    "$SCRIPT_DIR/claude-cron.sh" > "$CRON_LIB"

if ! grep -q '^parse_schedule()' "$CRON_LIB"; then
    echo "  [FAIL] could not extract claude-cron's schedule functions for testing"
    FAILED=$((FAILED + 1))
fi

assert_schedule() {
    local spec="$1" expected="$2" actual
    actual=$( cd "$SCRIPT_DIR" && . "$CRON_LIB"; parse_schedule "$spec" 2>/dev/null || echo "REJECTED" )
    if [ "$actual" = "$expected" ]; then
        echo "  [PASS] schedule '${spec}' -> ${expected}"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] schedule '${spec}' -> ${actual}, expected ${expected}"
        FAILED=$((FAILED + 1))
    fi
}

assert_schedule "30"                "interval 1800"
assert_schedule "every 30m"         "interval 1800"
assert_schedule "every 6h"          "interval 21600"
assert_schedule "every 2d"          "interval 172800"
assert_schedule "daily 03:15"       "cron 15 3 * * *"
# 08 and 09 are not octal here. Bash arithmetic reads a leading zero as octal
# and would abort on "08", so the hour and minute are forced to base 10.
assert_schedule "daily 08:09"       "cron 9 8 * * *"
assert_schedule "0 3 * * *"         "cron 0 3 * * *"
assert_schedule "*/15 8-22 * * 1-5" "cron */15 8-22 * * 1-5"
assert_schedule "banana"            "REJECTED"
assert_schedule "daily 25:00"       "REJECTED"
assert_schedule "every 0m"          "REJECTED"
assert_schedule "1 2 3"             "REJECTED"
# Named months and weekdays are not implemented. Accepting them would produce a
# job that parses and then never fires, which is the worst of both.
assert_schedule "0 3 * JAN *"       "REJECTED"

# Every cron field can be a literal "*". Splitting one without disabling
# globbing expands it to the contents of the working directory -- which for a
# scheduled job is /config -- and the schedule then silently matches nothing.
# This assertion is run from a deliberately NON-EMPTY directory for that reason.
cron_matches_now=$( cd "$SCRIPT_DIR" && . "$CRON_LIB"
    m=$((10#$(date +%M))); h=$((10#$(date +%H)))
    if cron_due_now "$m" "$h" "*" "*" "*"; then echo yes; else echo no; fi )
if [ "$cron_matches_now" = "yes" ]; then
    echo "  [PASS] cron wildcards survive word splitting in a non-empty directory"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] cron wildcards were glob-expanded; schedules would never fire"
    FAILED=$((FAILED + 1))
fi

echo "24. Testing claude-cron job management"

CRON_MGMT_DIR=$(mktemp -d)
export CRON_FILE="$CRON_MGMT_DIR/jobs.json"
export CRON_LOG_FILE="$CRON_MGMT_DIR/cron.log"
export CRON_OUTPUT_DIR="$CRON_MGMT_DIR/out"
export OPTIONS_FILE="$CRON_MGMT_DIR/options.json"
echo '{}' > "$OPTIONS_FILE"

"$SCRIPT_DIR/claude-cron.sh" add "daily 07:00" "Morning report" >/dev/null
"$SCRIPT_DIR/claude-cron.sh" add "every 15m" "Check the garage" >/dev/null
assert_exit_code 1 "$SCRIPT_DIR/claude-cron.sh" add "not a schedule" "should be refused"

"$SCRIPT_DIR/claude-cron.sh" disable 1 >/dev/null
# jq's // returns its right-hand side for FALSE as well as for null, so
# `.enabled // true` reads a paused job back as enabled. That is not a display
# bug: the daemon shares this test, and a paused job would keep running.
if "$SCRIPT_DIR/claude-cron.sh" list | grep -q '(paused)'; then
    echo "  [PASS] a disabled job reads back as paused"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] a disabled job still reads back as enabled (jq // on false)"
    FAILED=$((FAILED + 1))
fi

"$SCRIPT_DIR/claude-cron.sh" enable 1 >/dev/null
if ! "$SCRIPT_DIR/claude-cron.sh" list | grep -q '(paused)'; then
    echo "  [PASS] enable resumes a paused job"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] enable did not resume the job"
    FAILED=$((FAILED + 1))
fi

assert_exit_code 1 "$SCRIPT_DIR/claude-cron.sh" disable 99
assert_exit_code 1 "$SCRIPT_DIR/claude-cron.sh" remove 99
assert_exit_code 1 "$SCRIPT_DIR/claude-cron.sh" output notanumber

# Jobs written before schedules existed carry interval_min and no schedule
# field. An upgrade must not strand them.
jq '.jobs += [{"id": 9, "interval_min": 45, "prompt": "Legacy job", "last_timestamp": 0}]' \
    "$CRON_FILE" > "$CRON_FILE.tmp" && mv "$CRON_FILE.tmp" "$CRON_FILE"
if "$SCRIPT_DIR/claude-cron.sh" list | grep -q 'every 45m'; then
    echo "  [PASS] pre-upgrade interval_min jobs still list correctly"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] pre-upgrade interval_min jobs are not understood"
    FAILED=$((FAILED + 1))
fi

# The scheduled path used to run a bare `claude -p`, ignoring the permission
# flags the Automation API applied -- so the same prompt worked from an
# automation and silently refused to change anything on a schedule.
if grep -q 'dangerously_skip_permissions' "$SCRIPT_DIR/claude-cron.sh" \
    && grep -q 'claude_extra_args' "$SCRIPT_DIR/claude-cron.sh"; then
    echo "  [PASS] claude-cron applies the add-on's Claude flags"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-cron does not read the permission flags from options"
    FAILED=$((FAILED + 1))
fi

# Scheduled runs must silence the completion hook, or every job notifies twice.
if grep -q 'CLAUDE_TERMINAL_NO_HOOK_NOTIFY=1 claude -p' "$SCRIPT_DIR/claude-cron.sh"; then
    echo "  [PASS] scheduled runs suppress the interactive completion hook"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] scheduled runs would notify twice (hook plus job report)"
    FAILED=$((FAILED + 1))
fi

unset CRON_FILE CRON_LOG_FILE CRON_OUTPUT_DIR OPTIONS_FILE
rm -rf "$CRON_MGMT_DIR"

echo "25. Testing that run.sh installs and starts the new subsystems"

for cmd in ha-entity claude-hooks claude-usage claude-session; do
    if grep -q "\"${cmd}:/opt/scripts/" "$RUN_SH"; then
        echo "  [PASS] run.sh installs ${cmd}"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] run.sh does not install ${cmd}"
        FAILED=$((FAILED + 1))
    fi
done

# state-lib.sh is sourced, not run. Installing it as a command would put a file
# in /usr/local/bin that does nothing; NOT shipping it breaks every script that
# sources it, which is why ci/smoke.sh checks for the file separately.
if ! grep -q '"state-lib:/opt/scripts/' "$RUN_SH"; then
    echo "  [PASS] state-lib.sh is not installed as a command"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] state-lib.sh is installed as a command; it is a sourced library"
    FAILED=$((FAILED + 1))
fi

for step in install_hooks start_entity_heartbeat start_context_refresh notify_ingress_advisory; do
    if grep -qE "^    ${step}$" "$RUN_SH"; then
        echo "  [PASS] run.sh main() calls ${step}"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] run.sh main() never calls ${step}"
        FAILED=$((FAILED + 1))
    fi
done

# Home Assistant does not persist states created through its REST API, so a
# one-shot publish works until Core restarts and then silently stops forever.
if grep -q 'ha-entity heartbeat' "$RUN_SH"; then
    echo "  [PASS] entity publishing runs as a heartbeat, not once at boot"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] entities are published once and would vanish on an HA restart"
    FAILED=$((FAILED + 1))
fi

echo "26. Testing options survive an unreadable Supervisor config"

# `bashio::config key default` does NOT return the default when the Supervisor
# API call fails -- it logs an error and returns an EMPTY string. Options tested
# with `= "true"` therefore took their else branch on a transient API hiccup:
# auto_launch_claude silently dropped the user into a shell instead of Claude,
# and the Automation API was launched with `--port ''` and refused to start.
# config_or is the guard; these assertions stop a future edit from reaching
# past it.
for guarded in auto_launch_claude enable_ha_entities ha_context_refresh_hours \
               enable_automation_api automation_api_port; do
    if grep -q "config_or '${guarded}'" "$RUN_SH"; then
        echo "  [PASS] ${guarded} is read through config_or"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] ${guarded} is read without the empty-config guard"
        FAILED=$((FAILED + 1))
    fi
done

# The guard itself, exercised against every answer bashio can give.
#
# This cannot be tested by booting the container: outside a Supervisor,
# bashio::config fails for EVERY key and returns empty, so a container run
# cannot distinguish "the option was honoured" from "the default was
# substituted". Stubbing bashio is the only way to prove the case that matters
# in production -- that a real `false` is still passed through and not
# overwritten by the default.
eval "$(awk '/^config_or\(\) \{/,/^\}/' "$RUN_SH")"

assert_config_or() {
    local expected="$1" label="$2" actual
    actual=$(config_or 'some_option' 'true')
    if [ "$actual" = "$expected" ]; then
        echo "  [PASS] config_or: $label -> $actual"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] config_or: $label -> ${actual}, expected ${expected}"
        FAILED=$((FAILED + 1))
    fi
}

# The one that would be a regression: the user's explicit false must survive.
bashio::config() { echo "false"; }; assert_config_or "false" "an explicit false is honoured"
bashio::config() { echo "true"; };  assert_config_or "true"  "an explicit true is honoured"
# The three failure shapes that used to leak an empty string to the caller.
bashio::config() { echo ""; };      assert_config_or "true"  "an empty answer falls back"
bashio::config() { echo "null"; };  assert_config_or "true"  "a null answer falls back"
bashio::config() { return 1; };     assert_config_or "true"  "a failing bashio falls back"
unset -f bashio::config

# require_ingress_user is the deliberate exception. It must fail CLOSED: an
# unreadable config has to mean "enforce", which is why the enforcement branch
# tests for anything that is NOT an explicit "false" rather than testing for
# "true". Testing for "true" would mean an empty answer from a stuttering
# Supervisor API silently dropped authentication on a running root shell.
if grep -q 'if \[ "$require_user" != "false" \]; then' "$RUN_SH"; then
    echo "  [PASS] ingress enforcement treats anything but an explicit false as ON"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] ingress enforcement no longer fails closed on an unreadable config"
    FAILED=$((FAILED + 1))
fi

# ...and it must never acquire a fallback that can produce "false".
if ! grep -q "require_ingress_user' 'false'" "$RUN_SH"; then
    echo "  [PASS] require_ingress_user has no insecure default anywhere"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] require_ingress_user is read somewhere with a 'false' default"
    FAILED=$((FAILED + 1))
fi

echo "27. Testing blueprint installation covers every bundled blueprint"

# install_blueprint used to name ONE file. Adding blueprints to the image
# without generalising it ships them nowhere.
if grep -q 'for src in /opt/blueprints/\*.yaml' "$RUN_SH"; then
    echo "  [PASS] run.sh installs every bundled blueprint"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] run.sh still installs a single hardcoded blueprint"
    FAILED=$((FAILED + 1))
fi

# Upgrading from the single-baseline layout must move the old baseline across.
# Without that migration the original blueprint looks like it has no baseline,
# which reads as "safe to overwrite" -- destroying exactly the local edits the
# baseline exists to protect.
if grep -q 'migrate_blueprint_baseline' "$RUN_SH"; then
    echo "  [PASS] the pre-upgrade blueprint baseline is migrated"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] upgrading would discard the old blueprint baseline"
    FAILED=$((FAILED + 1))
fi

# Every blueprint can act on Home Assistant, so each needs an explicit
# concurrency guard -- single where a pile-up would compound, queued where
# dropping a run would lose the only copy of a result.
for bp in "$BLUEPRINT_DIR"/*.yaml; do
    bp_name=$(basename "$bp")
    if grep -qE '^mode: (single|queued)$' "$bp" && grep -q '^max_exceeded: silent$' "$bp"; then
        echo "  [PASS] ${bp_name} declares a concurrency guard"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] ${bp_name} has no explicit mode/max_exceeded"
        FAILED=$((FAILED + 1))
    fi
done

echo "28. Regressions found by adversarial review"

REVIEW_DIR=$(mktemp -d)

# jq's // yields its RHS for FALSE as well as null, so `.[$k] // empty` read
# every boolean option back as its default -- notify_on_completion: false and
# enable_ha_entities: false were impossible to turn off, and the hooks were
# reinstalled on every boot regardless.
echo '{"notify_on_completion": false, "enable_ha_entities": false}' > "$REVIEW_DIR/options.json"
export OPTIONS_FILE="$REVIEW_DIR/options.json"
export CLAUDE_HOOKS_SETTINGS="$REVIEW_DIR/settings.json"

# NOT piped straight into `grep -q`: it closes the pipe on its first match, the
# producer dies of SIGPIPE, and `set -o pipefail` then fails the pipeline even
# though the match succeeded. Capture, then match.
hooks_status=$("$SCRIPT_DIR/claude-hooks.sh" status 2>/dev/null || true)
if printf '%s\n' "$hooks_status" | grep -q '^Notifications: *false'; then
    echo "  [PASS] a boolean option set to false is honoured, not defaulted"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] notify_on_completion: false was read back as true (jq // on false)"
    FAILED=$((FAILED + 1))
fi

"$SCRIPT_DIR/claude-hooks.sh" install >/dev/null 2>&1 || true
if [ "$(jq -r '(.hooks // {}) | length' "$CLAUDE_HOOKS_SETTINGS" 2>/dev/null)" = "0" ]; then
    echo "  [PASS] both features off installs no hooks at all"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] hooks were installed despite both options being off"
    FAILED=$((FAILED + 1))
fi
unset OPTIONS_FILE CLAUDE_HOOKS_SETTINGS

# Without jq -R, `fromjson` runs on an already-parsed object, errors, is
# swallowed by `?`, and the completion notification never carried what Claude
# said -- the one thing that feature advertises.
cat > "$REVIEW_DIR/transcript.jsonl" << 'TRANSCRIPT'
{"type":"user","message":{"content":"hi"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"I fixed the porch light."}]}}
TRANSCRIPT
eval "$(awk '/^last_assistant_text\(\)/,/^\}/' "$SCRIPT_DIR/claude-hooks.sh")"
if [ "$(last_assistant_text "$REVIEW_DIR/transcript.jsonl")" = "I fixed the porch light." ]; then
    echo "  [PASS] the completion notification carries Claude's last message"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] last_assistant_text is empty (jq needs -R on a JSONL stream)"
    FAILED=$((FAILED + 1))
fi

# A lock path that rmdir can never remove (a regular file, or /data gone
# read-only) used to spin the retry loop at 100% of a core FOREVER: the
# stale-break path neither counted an attempt nor slept, so the wait budget was
# never consulted. On the boot path that meant the terminal never opened.
: > "$REVIEW_DIR/spin.json.lock"
touch -t 202501010000 "$REVIEW_DIR/spin.json.lock"
spin_start=$(date +%s)
STATE_LOCK_WAIT_SECONDS=2 json_update "$REVIEW_DIR/spin.json" '{}' '.x = 1' >/dev/null 2>&1 || true
spin_elapsed=$(( $(date +%s) - spin_start ))
if [ "$spin_elapsed" -lt 15 ]; then
    echo "  [PASS] an unremovable lock gives up (${spin_elapsed}s) instead of spinning"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] state_lock spun for ${spin_elapsed}s on an unremovable lock"
    FAILED=$((FAILED + 1))
fi

# "08" passes the all-digits filter and is then invalid octal to bash
# arithmetic -- a FATAL expansion error, so `add` died with a raw bash message
# and created nothing.
export CRON_FILE="$REVIEW_DIR/cron.json"
export CRON_LOG_FILE="$REVIEW_DIR/cron.log"
export CRON_OUTPUT_DIR="$REVIEW_DIR/out"
export OPTIONS_FILE="$REVIEW_DIR/options.json"
if "$SCRIPT_DIR/claude-cron.sh" add "08" "leading zero" >/dev/null 2>&1 \
    && "$SCRIPT_DIR/claude-cron.sh" list | grep -q 'leading zero'; then
    echo "  [PASS] a leading-zero interval is accepted, not an octal fatal error"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-cron add \"08\" fails on bash octal arithmetic"
    FAILED=$((FAILED + 1))
fi
unset CRON_FILE CRON_LOG_FILE CRON_OUTPUT_DIR OPTIONS_FILE

# 7 is standard crontab for Sunday, but `date +%w` only emits 0-6, so
# "0 3 * * 7" was accepted by add and then matched nothing for ever -- exactly
# the failure named weekdays are rejected to avoid.
dow_check=$( cd "$SCRIPT_DIR" && . "$CRON_LIB"
    now_dow=0; now_dow_alt=7
    if dow_matches_now 7 && dow_matches_now 0 && dow_matches_now "1-7"; then echo ok; fi
    )
if [ "$dow_check" = "ok" ]; then
    echo "  [PASS] day-of-week 7 means Sunday, as in every other crontab"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] dow=7 never matches, so such a job would never fire"
    FAILED=$((FAILED + 1))
fi

# busybox date parses NEITHER "-7 days" nor -v, so the cutoff silently became
# 0000-00-00 and --days was ignored on the only platform that ships this image.
# @epoch is understood by busybox, GNU and BSD alike.
if grep -q 'date -u -d "@\$((' "$SCRIPT_DIR/claude-usage.sh"; then
    echo "  [PASS] claude-usage computes its cutoff from an epoch offset"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-usage uses a relative date string busybox cannot parse"
    FAILED=$((FAILED + 1))
fi

# tmux -t is a prefix/fnmatch pattern, not a name: `kill clau` would resolve to
# the primary session while the "is this the primary?" guard saw something else.
if grep -q 'exact()' "$SCRIPT_DIR/claude-session.sh" \
    && ! grep -qE 'tmux (has-session|kill-session|switch-client|attach-session) -t "\$name"' "$SCRIPT_DIR/claude-session.sh"; then
    echo "  [PASS] tmux targets are exact, so the primary session cannot be hit by a prefix"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] claude-session passes unanchored names to tmux -t"
    FAILED=$((FAILED + 1))
fi

# Nothing on the boot path may hit the network. The entity seed publishes six
# entities over HTTP; in the foreground that was up to a full curl timeout
# before ttyd started, in the window where Core is slowest.
# Checking POSITION, not presence: the seed publish is fine inside the
# backgrounded subshell and fatal before it, and both are indented the same, so
# grepping the whole function proves nothing. Take only the part of the function
# above the subshell opener.
heartbeat_prelude=$(sed -n '/^start_entity_heartbeat()/,/^}/p' "$RUN_SH" | sed -n '1,/^    ($/p')
if ! printf '%s\n' "$heartbeat_prelude" | grep -qE '^ *ha-entity (set|heartbeat)'; then
    echo "  [PASS] the entity seed publish is off the boot path"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] start_entity_heartbeat publishes synchronously before ttyd starts"
    FAILED=$((FAILED + 1))
fi

if grep -q 'publish_all' "$SCRIPT_DIR/ha-entity.sh"; then
    echo "  [PASS] entity publishes are concurrent, bounding worst-case latency"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] entities publish sequentially: six curl timeouts back to back"
    FAILED=$((FAILED + 1))
fi

rm -rf "$REVIEW_DIR"
rm -f "$CRON_LIB"

echo ""
echo "=== Shell Script Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
