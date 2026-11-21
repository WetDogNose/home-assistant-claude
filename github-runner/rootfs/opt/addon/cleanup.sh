#!/bin/bash
# Kill whatever an earlier job left behind: stray processes in this container,
# and job containers the docker wrapper labelled on the host. Called by the
# job-started and job-completed hooks; never fails the job.
set -u

LABEL=io.github.wetdognose.runner-job=1

# Protected: PID 1 (tini), this script and its ancestors (the hook runs under
# Runner.Worker), the runner itself and the add-on's own scripts. A child of
# those scripts (heartbeat's `sleep`) may be killed; that only brings the next
# heartbeat forward.
declare -A keep=([1]=1)
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
  keep[$p]=1
  p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1)
done
while read -r pid; do
  keep[$pid]=1
done < <(pgrep -f 'Runner\.(Listener|Worker)|/opt/addon/|/data/runner/(run|run-helper)\.sh|/data/runner/bin')

victims=()
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  [ -n "${keep[$pid]:-}" ] && continue
  victims+=("$pid")
done

if [ "${#victims[@]}" -gt 0 ]; then
  echo "[cleanup] terminating ${#victims[@]} leftover process(es)"
  kill -TERM "${victims[@]}" 2>/dev/null || true
  sleep 3
  kill -KILL "${victims[@]}" 2>/dev/null || true
fi

containers=$(/usr/bin/docker ps -aq --filter "label=${LABEL}" 2>/dev/null || true)
if [ -n "$containers" ]; then
  echo "[cleanup] removing leftover job container(s): $(echo "$containers" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  /usr/bin/docker rm -f $containers >/dev/null 2>&1 || true
fi

exit 0
