#!/bin/bash
# Entrypoint: register once, then keep one runner listening, at low priority.
set -euo pipefail

OPTIONS=/data/options.json
RUNNER_DIR=/data/runner
WORK_DIR=/data/work

opt() { jq -r --arg k "$1" '.[$k] // ""' "$OPTIONS"; }

log() { echo "[github-runner] $*"; }

repository=$(opt repository)
token=$(opt registration_token)
name=$(opt runner_name)
labels=$(opt labels)

if [ -z "$repository" ]; then
  log "Set the 'repository' option first."
  exit 1
fi

# Where the host sees /data. Job steps run `docker run -v "$(pwd)":...`, and the
# HOST's daemon resolves that path, so the docker wrapper translates /data/...
# into this. Without it, every mount of the workspace would be an empty dir.
container_id=$(grep -oE '/containers/[0-9a-f]{64}/' /proc/self/mountinfo | head -n1 | cut -d/ -f3 || true)
host_data=""
if [ -n "$container_id" ]; then
  host_data=$(/usr/bin/docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' \
    "$container_id" 2>/dev/null || true)
fi
if [ -z "$host_data" ]; then
  log "Cannot reach the host's Docker daemon. Turn protection mode OFF for this add-on, then restart it."
  exit 1
fi
export RUNNER_HOST_DATA="$host_data"
log "Host path of /data: $host_data"

# The runner lives in /data so its registration and self-updates survive an
# add-on rebuild. Only a first start copies it from the image.
if [ ! -x "$RUNNER_DIR/run.sh" ]; then
  log "Installing runner into $RUNNER_DIR"
  mkdir -p "$RUNNER_DIR"
  cp -a /opt/actions-runner/. "$RUNNER_DIR/"
fi
mkdir -p "$WORK_DIR"
cd "$RUNNER_DIR"

# It is root in this container either way, and Docker access is root on the host.
export RUNNER_ALLOW_RUNASROOT=1

if [ ! -f "$RUNNER_DIR/.runner" ]; then
  if [ -z "$token" ]; then
    log "Not registered yet. Put a registration token (valid for 1 hour) in 'registration_token' and restart."
    exit 1
  fi
  log "Registering '$name' with $repository (labels: $labels)"
  ./config.sh --unattended --replace \
    --url "$repository" --token "$token" \
    --name "$name" --labels "$labels" --work "$WORK_DIR"
fi

# Clean up before and after every job. The runner only runs hook scripts whose
# name ends in .sh.
export ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/addon/job-started.sh
export ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/addon/job-completed.sh

/opt/addon/heartbeat.sh &
heartbeat_pid=$!

child=""
stop() {
  log "Stopping"
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null || true
  kill "$heartbeat_pid" 2>/dev/null || true
  wait || true
  exit 0
}
trap stop TERM INT

# One runner instance is one job at a time. nice/ionice keep Home Assistant
# ahead of CI for CPU and disk; the docker wrapper does the same for job
# containers, which run under the host daemon and do not inherit this.
while true; do
  nice -n 10 ionice -c 3 ./run.sh &
  child=$!
  wait "$child" || log "Runner exited with status $?"
  child=""
  log "Restarting the runner in 30s"
  sleep 30 &
  wait $! || true
done
