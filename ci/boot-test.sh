#!/usr/bin/env bash
# Boot the add-on and assert it actually serves.
#
# run.sh has never been executed by CI. Everything until now tested the image's
# contents, not whether the thing starts -- so a broken boot path would first be
# discovered by a user with a blank panel.
#
# Asserts:
#   1. ttyd listens on 7681 within the budget (i.e. provisioning is NOT blocking)
#   2. an unauthenticated request is refused           (ingress identity enforced)
#   3. a request carrying X-Remote-User-Id is served   (enforcement isn't a wall)
#   4. run.sh logged no fatal error
set -uo pipefail
IMAGE="${1:?usage: ci/boot-test.sh <image-ref>}"
NAME="boot-test-$$"
WORK=$(mktemp -d)
rc=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/data" "$WORK/config"
# bashio falls back to schema defaults outside a Supervisor, but be explicit:
# auto_launch_claude off keeps the test independent of Anthropic credentials.
cat > "$WORK/data/options.json" <<'JSON'
{"auto_launch_claude": false, "claude_auto_update": false,
 "ha_smart_context": false, "enable_ha_mcp": false,
 "require_ingress_user": true}
JSON

echo "== booting =="
docker run -d --name "$NAME" -p 17681:7681 \
  -v "$WORK/data:/data" -v "$WORK/config:/config" "$IMAGE" >/dev/null

echo "== 1. ttyd listens within 60s (proves provisioning does not block) =="
listening=0
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null -m 2 -H 'X-Remote-User-Id: ci' http://127.0.0.1:17681/ 2>/dev/null; then
    echo "OK: serving after ${i}s"; listening=1; break
  fi
  # a container that died will never listen; fail fast with its log
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
    echo "FAIL: container exited during boot"; docker logs "$NAME" 2>&1 | tail -30; rc=1; break
  fi
  sleep 1
done
if [ "$listening" -ne 1 ] && [ "$rc" -eq 0 ]; then
  echo "FAIL: ttyd never listened on 7681"; docker logs "$NAME" 2>&1 | tail -30; rc=1
fi

if [ "$listening" -eq 1 ]; then
  echo "== 2. unauthenticated request is refused =="
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:17681/ || echo 000)
  if [ "$code" = "401" ] || [ "$code" = "407" ]; then
    echo "OK: no identity -> HTTP $code"
  else
    echo "FAIL: no identity -> HTTP $code (expected 401/407)"; rc=1
  fi

  echo "== 3. request with ingress identity is served =="
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
    -H 'X-Remote-User-Id: 00000000-0000-0000-0000-000000000000' \
    http://127.0.0.1:17681/ || echo 000)
  if [ "$code" = "200" ]; then echo "OK: identity -> HTTP 200"
  else echo "FAIL: identity -> HTTP $code (expected 200)"; rc=1; fi
fi

# The container's OWN healthcheck must pass, not just our probe. These are
# different requests: ours sends the ingress identity, the HEALTHCHECK is
# whatever the Dockerfile says. When ttyd began requiring the header and the
# HEALTHCHECK did not send it, every assertion below still passed while the
# Supervisor saw an app that never became healthy and restarted it forever.
echo "== 4. container reports HEALTHY (not just serving) =="
health="none"
for i in $(seq 1 60); do
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo none)
  case "$health" in
    healthy)   echo "OK: healthy after ${i}s"; break ;;
    unhealthy) echo "FAIL: reported unhealthy"; rc=1; break ;;
  esac
  sleep 1
done
if [ "$health" = "none" ]; then
  echo "FAIL: image declares no HEALTHCHECK, so the Supervisor can never detect a dead terminal"; rc=1
elif [ "$health" != "healthy" ] && [ "$health" != "unhealthy" ]; then
  echo "FAIL: still '$health' after 60s"
  docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$NAME" 2>/dev/null | tail -5
  rc=1
fi

echo "== 5. boot path logged no fatal error =="
if docker logs "$NAME" 2>&1 | grep -iE '^\[[0-9:]+\] FATAL|command not found|No such file or directory' | head -5; then
  echo "FAIL: errors in the boot log (above)"; rc=1
else
  echo "OK: clean boot log"
fi

echo "--- boot log (tail) ---"
docker logs "$NAME" 2>&1 | tail -20

[ "$rc" -eq 0 ] && echo "BOOT TEST: PASS" || echo "BOOT TEST: FAIL"
exit $rc
