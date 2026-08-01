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
for bp in "$BLUEPRINT_DIR"/*.yaml; do
    # Home Assistant blueprints use the custom !input tag, which safe_load
    # rejects; register it so the check tests YAML validity, not tag support.
    if python3 -c "
import sys, yaml
class L(yaml.SafeLoader): pass
L.add_constructor('!input', lambda loader, node: loader.construct_scalar(node))
yaml.load(open(sys.argv[1]), Loader=L)
" "$bp" 2>/dev/null; then
        echo "  [PASS] $(basename "$bp") is valid YAML"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] $(basename "$bp") is not valid YAML"
        FAILED=$((FAILED + 1))
    fi
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

echo ""
echo "=== Shell Script Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
