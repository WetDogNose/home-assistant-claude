#!/usr/bin/env bash
# Smoke-test a built Claude Terminal image.
#
# Extracted from build-test.yml so CI, the canary and a developer all run the
# SAME assertions. Two copies of these lists is how the base image ended up
# declared in three places that could disagree.
#
# Usage: ci/smoke.sh <image-ref> [--exec]
#   default   presence + relocation checks (safe under QEMU emulation)
#   --exec    also execute each binary (native architecture only)

set -uo pipefail
IMAGE="${1:?usage: ci/smoke.sh <image-ref> [--exec]}"
MODE="${2:-}"
rc=0

run() { docker run --rm -i --entrypoint /bin/bash "$IMAGE" -s; }

echo "== scripts are executable =="
if ! run <<'IN'
rc=0
for s in /run.sh /opt/scripts/setup-ha-mcp.sh /opt/scripts/health-check.sh \
         /opt/scripts/persist-install.sh /opt/scripts/ha-context.sh \
         /opt/scripts/github-setup.sh /opt/scripts/claude-launch.sh \
         /opt/scripts/data-gc.sh /opt/scripts/welcome.sh; do
  if [ -x "$s" ]; then echo "OK: $s"; else echo "FAIL: $s not executable"; rc=1; fi
done
exit $rc
IN
then rc=1; fi

# ldd resolves relocations WITHOUT executing, so it is safe under qemu-user
# where running a JIT binary is not. This is the check that catches a binary
# that is present, +x, and aborts on exec.
echo "== relocations resolve =="
if ! run <<'IN'
rc=0
for b in claude gh ttyd tmux node jq curl uv git; do
  p=$(command -v "$b") || { echo "FAIL: $b not found"; rc=1; continue; }
  out=$(ldd "$p" 2>&1 || true)
  if printf '%s' "$out" | grep -q 'symbol not found'; then
    echo "FAIL: $b has unresolved symbols:"; printf '%s\n' "$out" | grep 'symbol not found'; rc=1
  else echo "OK(ldd): $b"; fi
done
exit $rc
IN
then rc=1; fi

if [ "$MODE" = "--exec" ]; then
  echo "== binaries actually run =="
  if ! run <<'IN'
rc=0
check() { n=$1; shift
  if out=$(timeout 30 "$@" 2>&1); then echo "OK: $n -> $(printf '%s' "$out" | head -1)"
  else echo "FAIL: $n did not run: $(printf '%s' "$out" | head -3)"; rc=1; fi; }
check claude claude --version; check gh gh --version; check uv uv --version
check node node --version;     check npm npm --version; check git git --version
check jq jq --version;         check tmux tmux -V;      check python3 python3 --version
check yq yq --version
exit $rc
IN
  then rc=1; fi
fi

echo "== versions =="
run <<'IN' || true
cat /usr/local/share/claude-terminal/build-versions.json 2>/dev/null || echo '{}'
echo "alpine: $(cat /etc/alpine-release)"
apk info -v 2>/dev/null | sort | grep -E '^(git|github-cli|nodejs|tmux|ttyd|python3|yq-go)-[0-9]' || true
IN

[ "$rc" -eq 0 ] && echo "SMOKE: PASS" || echo "SMOKE: FAIL"
exit $rc
