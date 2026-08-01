#!/usr/bin/env bash
# Local pre-commit / pre-flight validation runner.
# Runs static analysis, documentation drift check, and automated unit tests.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "========================================="
echo "1/4 Running ShellCheck Static Analysis..."
echo "========================================="
shellcheck -s bash -e SC1008 -e SC1091 -e SC2016 -e SC2129 -e SC1003 -e SC2002 \
    claude-terminal/run.sh claude-terminal/scripts/*.sh
echo "ShellCheck: PASS"
echo ""

echo "========================================="
echo "2/4 Running Options & Docs Drift Check..."
echo "========================================="
./ci/check-docs-drift.sh
echo ""

echo "========================================="
echo "3/4 Running Shell Script Unit Tests..."
echo "========================================="
./tests/test_scripts.sh
echo ""

echo "========================================="
echo "4/4 Running Python API Unit Tests..."
echo "========================================="
python3 -m unittest discover tests/
echo ""

echo "========================================="
echo "ALL LOCAL VALIDATION CHECKS PASSED CLEANLY!"
echo "========================================="
