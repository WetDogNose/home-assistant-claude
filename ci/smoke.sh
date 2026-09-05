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
         /opt/scripts/data-gc.sh /opt/scripts/ha-notify.sh /opt/scripts/welcome.sh \
         /opt/scripts/claude-api-server.py /opt/scripts/claude-login-notifier.sh \
         /opt/scripts/ha-snapshot.sh /opt/scripts/ha-validate.sh \
         /opt/scripts/ha-scaffold.sh /opt/scripts/esphome-setup.sh \
         /opt/scripts/ha-tts.sh /opt/scripts/claude-cron.sh \
         /opt/scripts/ha-diagnose.sh /opt/scripts/ha-dashboard.sh \
         /opt/scripts/ha-mesh.sh /opt/scripts/ha-assist.sh \
         /opt/scripts/ha-memory.sh /opt/scripts/claude-bot.sh \
         /opt/scripts/ha-git-backups.sh /opt/scripts/ha-entity.sh \
         /opt/scripts/claude-hooks.sh /opt/scripts/claude-usage.sh \
         /opt/scripts/claude-session.sh; do
  if [ -x "$s" ]; then echo "OK: $s"; else echo "FAIL: $s not executable"; rc=1; fi
done
exit $rc
IN
then rc=1; fi

# login-url-lib.sh is sourced, never invoked, so it is absent from the command
# list above -- and a missing copy of it takes the sign-in notification down
# silently, which is the failure this add-on can least afford.
echo "== sourced libraries are present =="
if ! run <<'IN'
rc=0
for l in /opt/scripts/login-url-lib.sh /opt/scripts/state-lib.sh; do
  if [ -f "$l" ]; then echo "OK: $l"; else echo "FAIL: $l missing"; rc=1; fi
done
exit $rc
IN
then rc=1; fi

# Skills are what tell the Claude session inside the add-on how its own tooling
# works. A skill missing from the image fails silently -- Claude simply never
# learns the command exists -- so the shipped set is asserted here rather than
# left to be noticed in use.
echo "== skills are present =="
if ! run <<'IN'
rc=0
for s in ha-config-safety ha-diagnostics ha-history ha-dashboards \
         ha-integration-dev ha-camera-vision ha-announce \
         claude-automation-api claude-scheduled-tasks \
         claude-terminal-notifications claude-terminal-sessions; do
  f="/opt/skills/$s/SKILL.md"
  if [ ! -f "$f" ]; then echo "FAIL: $f missing"; rc=1; continue; fi
  # The frontmatter is the whole triggering mechanism: no name/description and
  # the skill is inert even though the file shipped.
  if ! head -1 "$f" | grep -q '^---$'; then echo "FAIL: $s has no frontmatter"; rc=1; continue; fi
  if ! grep -q "^name: ${s}$" "$f"; then echo "FAIL: $s name does not match its directory"; rc=1; continue; fi
  if ! grep -q '^description: .' "$f"; then echo "FAIL: $s has no description"; rc=1; continue; fi
  echo "OK: $s"
done
exit $rc
IN
then rc=1; fi

# Blueprints are copied into /config the first time the add-on starts, and only
# then -- so one missing from the image is not noticed at boot, it is noticed
# when a user goes looking for an automation blueprint the release notes
# promised and finds nothing there.
echo "== blueprints are present =="
if ! run <<'IN'
rc=0
for b in claude_automation_query claude_terminal_ask \
         claude_terminal_scheduled_report claude_terminal_job_result; do
  f="/opt/blueprints/$b.yaml"
  if [ ! -f "$f" ]; then echo "FAIL: $f missing"; rc=1; continue; fi
  # Every one of these can act on Home Assistant, and an automation built from
  # a blueprint with no concurrency guard can pile runs on top of each other.
  grep -qE '^(mode: single|mode: queued)$' "$f" || { echo "FAIL: $b declares no run mode"; rc=1; continue; }
  grep -q '^max_exceeded: silent$' "$f" || { echo "FAIL: $b does not silence the drop"; rc=1; continue; }
  echo "OK: $b"
done
exit $rc
IN
then rc=1; fi

# The web client ttyd serves. It is generated at build time from the ttyd binary
# in the image, so unlike the files above it can go missing without any COPY
# having failed -- and its only symptom is that phones cannot type, which no
# check that asks "did the add-on boot?" would ever notice.
echo "== mobile key bar is baked into the served client =="
if ! run <<'IN'
rc=0
index=/opt/web/index.html
if [ ! -s "$index" ]; then
  echo "FAIL: $index missing or empty (ttyd would fall back to its stock client, with no touch keys)"; rc=1
else
  grep -q 'claude-terminal-mobile-keys' "$index" || { echo "FAIL: $index carries no key bar"; rc=1; }
  # ttyd's own client has to still be in there: appending is the whole design,
  # and an index.html that is ONLY our script is a blank terminal.
  grep -q 'xterm' "$index" || { echo "FAIL: $index is not ttyd's client"; rc=1; }
  [ "$(wc -c < "$index")" -gt 100000 ] || { echo "FAIL: $index is too small to be ttyd's client"; rc=1; }
  [ "$rc" -eq 0 ] && echo "OK: $index ($(wc -c < "$index") bytes, key bar present)"
fi
for f in /opt/web/mobile-keys.js /opt/web/build-index.py; do
  [ -f "$f" ] || { echo "FAIL: $f missing"; rc=1; }
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
