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

(
    # Mock /config/custom_components location by creating target dir
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

    # Verify manifest.json is valid JSON
    if jq . "$TARGET/manifest.json" >/dev/null 2>&1; then
        echo "  [PASS] ha-scaffold generated valid JSON manifest"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] ha-scaffold generated invalid JSON manifest"
        FAILED=$((FAILED + 1))
    fi
)

echo "5. Testing claude-cron.sh"
assert_exit_code 0 "$SCRIPT_DIR/claude-cron.sh" --help

(
    CRON_TEST_DIR=$(mktemp -d)
    export CRON_FILE="$CRON_TEST_DIR/claude-cron.json"
    
    # Add job
    "$SCRIPT_DIR/claude-cron.sh" add "30" "Test prompt" >/dev/null
    if grep -q "Test prompt" "$CRON_FILE"; then
        echo "  [PASS] claude-cron add succeeded"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] claude-cron add failed"
        FAILED=$((FAILED + 1))
    fi
    
    # List jobs
    if "$SCRIPT_DIR/claude-cron.sh" list | grep -q "Test prompt"; then
        echo "  [PASS] claude-cron list succeeded"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] claude-cron list failed"
        FAILED=$((FAILED + 1))
    fi
    
    # Remove job
    "$SCRIPT_DIR/claude-cron.sh" remove 1 >/dev/null
    if ! grep -q "Test prompt" "$CRON_FILE"; then
        echo "  [PASS] claude-cron remove succeeded"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] claude-cron remove failed"
        FAILED=$((FAILED + 1))
    fi
    
    rm -rf "$CRON_TEST_DIR"
)

echo "6. Testing ha-diagnose.sh"
DIAGNOSE_OUTPUT=$("$SCRIPT_DIR/ha-diagnose.sh")
if echo "$DIAGNOSE_OUTPUT" | grep -q "Diagnostic Report"; then
    echo "  [PASS] ha-diagnose output header valid"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] ha-diagnose output header invalid"
    FAILED=$((FAILED + 1))
fi

echo ""
echo "=== Shell Script Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
