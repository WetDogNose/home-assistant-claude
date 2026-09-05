#!/usr/bin/env python3
"""
Claude Terminal Automation API Server

Provides a secure, lightweight HTTP API for triggering Claude Code non-interactively
from Home Assistant automations, scripts, and REST commands.

Security controls:
- Token authentication via X-API-Key or Authorization header
- IP filtering (internal Docker bridge network / loopback only)
- Rate limiting and request size caps
- Execution serialization via thread mutex lock
- Safe subprocess execution with array arguments (no shell=True)

Three things beyond "run a prompt":

- ASYNC JOBS. A synchronous call was the only mode, and Home Assistant's
  rest_command times out after 10 seconds by default while a useful Claude
  prompt takes minutes. Practically every real automation therefore either gave
  up before Claude answered or held a connection open for the whole run. Posting
  with {"async": true} answers 202 immediately with a job id, and the result is
  collected from /api/jobs/<id> or -- better -- waited for as the Home Assistant
  event claude_terminal_job_finished.

- NAMED SESSIONS. Every call used to be a cold start with no memory of the last
  one, so an automation could ask Claude a question but never hold a
  conversation. A "session" key maps a name of your choosing to a Claude Code
  session that persists across calls.

- ENTITY STATE. Runs publish binary_sensor.claude_terminal_busy and friends
  through ha-entity, so Home Assistant can see that Claude is working rather
  than only being able to ask it to.
"""

import argparse
import collections
import hmac
import http.server
import json
import logging
import os
import re
import shlex
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from typing import Dict, List, Optional

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s [automation-api]: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger("claude-automation-api")

# Global state
EXECUTION_LOCK = threading.Lock()
RATE_LIMIT_LOCK = threading.Lock()
IP_REQUEST_TIMES: Dict[str, List[float]] = {}

MAX_PAYLOAD_BYTES = 65536  # 64 KB
MAX_REQUESTS_PER_MINUTE = 10

# Polling a job's status is not the same kind of request as starting one, and
# sharing the 10/min budget would make async jobs unusable: an automation that
# checks every 5 seconds spends the whole allowance in under a minute and then
# cannot read its own result. Reads are cheap and still authenticated, so they
# get their own, much larger bucket -- large enough to poll, small enough that
# it is not an unbounded oracle for a stolen-token guess.
MAX_POLL_REQUESTS_PER_MINUTE = 120

DEFAULT_TIMEOUT_SECONDS = 120
MAX_TIMEOUT_SECONDS = 300

# Async job registry. In memory on purpose: a job result is a transient answer
# to "did that finish?", and /data is included in Home Assistant backups, so
# persisting every prompt and reply there would quietly grow the backup with the
# contents of every automation Claude has ever answered. Jobs are lost on
# restart, which is documented, and the Home Assistant event fired on completion
# is the durable record for anything that matters.
JOBS: "collections.OrderedDict[str, dict]" = collections.OrderedDict()
JOBS_LOCK = threading.Lock()
MAX_TRACKED_JOBS = 50

# How many prompts are queued or running right now. binary_sensor.claude_
# terminal_busy is derived from this rather than from "did the job that just
# finished finish": with two jobs in flight, the first to complete used to
# publish busy=false while the second was still running, so the sensor lied for
# the whole of the second job.
ACTIVE_JOBS = 0
ACTIVE_LOCK = threading.Lock()


def _active_delta(delta: int) -> int:
    global ACTIVE_JOBS
    with ACTIVE_LOCK:
        ACTIVE_JOBS = max(0, ACTIVE_JOBS + delta)
        return ACTIVE_JOBS

# Name -> Claude session id, so an automation can hold a conversation across
# calls. Small and genuinely persistent state, unlike job results.
SESSIONS_FILE = os.environ.get("CLAUDE_API_SESSIONS_FILE", "/data/api-sessions.json")
SESSIONS_LOCK = threading.Lock()

SUPERVISOR_API = "http://supervisor"
JOB_FINISHED_EVENT = "claude_terminal_job_finished"


def is_trusted_ip(ip_str: str) -> bool:
    """Check if the client IP address is trusted (localhost or private container network)."""
    if ip_str in ("127.0.0.1", "::1", "localhost"):
        return True
    
    # Private IPv4 ranges (172.16.0.0/12, 10.0.0.0/8, 192.168.0.0/16)
    if ip_str.startswith("127.") or ip_str.startswith("10.") or ip_str.startswith("192.168."):
        return True
    
    if ip_str.startswith("172."):
        try:
            parts = [int(p) for p in ip_str.split(".")]
            if len(parts) == 4 and 16 <= parts[1] <= 31:
                return True
        except ValueError:
            pass
            
    return False


def check_rate_limit(ip_str: str, bucket: str = "run", limit: int = MAX_REQUESTS_PER_MINUTE) -> bool:
    """Allow at most `limit` requests per minute per caller, per bucket.

    Buckets keep starting a prompt and polling for its result on separate
    budgets: they have wildly different natural rates, and charging a status
    poll against the run budget is what would otherwise make an async job
    impossible to read back.
    """
    key = f"{bucket}:{ip_str}"
    now = time.time()
    with RATE_LIMIT_LOCK:
        times = IP_REQUEST_TIMES.setdefault(key, [])
        # Drop anything outside the trailing minute, then decide.
        times[:] = [t for t in times if now - t < 60]
        if len(times) >= limit:
            return False
        times.append(now)
        return True


def get_claude_binary_path() -> str:
    """Locate the Claude CLI executable."""
    persistent_claude = "/data/home/.local/bin/claude"
    if os.path.isfile(persistent_claude) and os.access(persistent_claude, os.X_OK):
        return persistent_claude
    bundled_claude = "/usr/local/bin/claude"
    if os.path.isfile(bundled_claude) and os.access(bundled_claude, os.X_OK):
        return bundled_claude
    return "claude"


def load_addon_options() -> dict:
    """Read options from /data/options.json if available."""
    options_file = "/data/options.json"
    if os.path.isfile(options_file):
        try:
            with open(options_file, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            logger.warning(f"Failed to read options.json: {e}")
    return {}


# --------------------------------------------------------------------------
# Talking back to Home Assistant
# --------------------------------------------------------------------------

def publish_state(**fields) -> None:
    """Update the add-on's own Home Assistant entities via ha-entity.

    Best effort by design and never raises: this is reporting, and reporting
    must not be able to break the run it is reporting on. ha-entity is absent
    in unit tests and outside the container, which is fine.
    """
    if not fields:
        return
    args = ["ha-entity", "set"] + [f"{k}={v}" for k, v in fields.items()]
    try:
        subprocess.run(args, capture_output=True, timeout=15, check=False)
    except Exception as e:  # FileNotFoundError outside the add-on, mostly
        logger.debug(f"Could not publish entity state: {e}")


def fire_ha_event(event_type: str, data: dict) -> bool:
    """Fire an event on Home Assistant's event bus.

    This is what makes an async job usable from an automation: rather than
    polling /api/jobs and burning the poll budget, the automation triggers on
    the event and receives the result in its trigger data. Without it, "start a
    long job" and "react to the answer" could not be the same automation.
    """
    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if not token:
        return False

    url = f"{SUPERVISOR_API}/core/api/events/{event_type}"
    body = json.dumps(data).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10):
            return True
    except Exception as e:
        logger.warning(f"Could not fire {event_type}: {e}")
        return False


# --------------------------------------------------------------------------
# Named conversations
# --------------------------------------------------------------------------

def _read_sessions() -> dict:
    try:
        with open(SESSIONS_FILE, "r", encoding="utf-8") as handle:
            data = json.load(handle)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _write_sessions(sessions: dict) -> None:
    try:
        os.makedirs(os.path.dirname(SESSIONS_FILE), exist_ok=True)
        tmp = f"{SESSIONS_FILE}.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(sessions, handle)
        # Rename rather than write in place: a reader must see either the whole
        # old mapping or the whole new one, never a truncated file.
        os.replace(tmp, SESSIONS_FILE)
    except Exception as e:
        logger.warning(f"Could not persist sessions: {e}")


def session_id_for(name: str) -> tuple:
    """Return (session_uuid, is_new) for a caller-chosen session name.

    The name is the automation's handle ("doorbell", "energy"); the uuid is what
    Claude Code understands. Keeping the mapping here means an automation never
    has to store or even see a session id.
    """
    with SESSIONS_LOCK:
        sessions = _read_sessions()
        existing = sessions.get(name)
        if isinstance(existing, str) and existing:
            return existing, False
        new_id = str(uuid.uuid4())
        sessions[name] = new_id
        _write_sessions(sessions)
        return new_id, True


def forget_session(name: str) -> None:
    """Drop a session mapping so the next call starts a fresh conversation."""
    with SESSIONS_LOCK:
        sessions = _read_sessions()
        if name in sessions:
            del sessions[name]
            _write_sessions(sessions)


# --------------------------------------------------------------------------
# Async jobs
# --------------------------------------------------------------------------

def _record_job(job: dict) -> None:
    with JOBS_LOCK:
        JOBS[job["job_id"]] = job
        # Oldest-first eviction. The cap is what stops a chatty automation from
        # turning this process into an ever-growing store of prompts and replies.
        while len(JOBS) > MAX_TRACKED_JOBS:
            JOBS.popitem(last=False)


def get_job(job_id: str) -> Optional[dict]:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        return dict(job) if job else None


def list_jobs() -> list:
    with JOBS_LOCK:
        # Newest first, and without the response bodies: a listing is for
        # "what has been running", and inlining every reply makes it enormous.
        return [
            {k: v for k, v in job.items() if k not in ("response", "error")}
            for job in reversed(list(JOBS.values()))
        ]


def _run_job(job_id: str, prompt: str, timeout: int, session: str) -> None:
    """Body of an async job: the same serialized execution a sync call gets."""
    acquired = EXECUTION_LOCK.acquire(blocking=True, timeout=float(timeout))
    if not acquired:
        finished = {
            "success": False,
            "error": "Timed out waiting for another Claude prompt to finish",
            "exit_code": -1,
        }
        _finish_job(job_id, finished, 0.0, session)
        return

    started = time.time()
    try:
        with JOBS_LOCK:
            if job_id in JOBS:
                JOBS[job_id]["status"] = "running"
                JOBS[job_id]["started_at"] = time.time()
        result = run_claude_prompt(prompt, timeout=timeout, session=session)
    except Exception as e:
        result = {"success": False, "error": str(e), "exit_code": -1}
    finally:
        EXECUTION_LOCK.release()

    _finish_job(job_id, result, time.time() - started, session)


def _finish_job(job_id: str, result: dict, duration: float, session: str) -> None:
    status = "completed" if result.get("success") else "failed"
    finished_at = time.time()

    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if job is not None:
            job.update(result)
            job["status"] = status
            job["duration_seconds"] = round(duration, 2)
            job["finished_at"] = finished_at

    still_busy = _active_delta(-1) > 0
    publish_state(
        busy="true" if still_busy else "false",
        status="running" if still_busy else "idle",
        last_result="ok" if status == "completed" else "error",
        last_source="api",
        last_run=time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(finished_at)),
    )

    # The response is truncated in the event: Home Assistant keeps every event
    # in its recorder, and a multi-kilobyte reply on the bus is a database
    # problem rather than a feature. The full text stays available at
    # /api/jobs/<id> for as long as the job is retained.
    response = result.get("response") or ""
    fire_ha_event(JOB_FINISHED_EVENT, {
        "job_id": job_id,
        "status": status,
        "success": bool(result.get("success")),
        "session": session or "",
        "duration_seconds": round(duration, 2),
        "response": response[:1000],
        "truncated": len(response) > 1000,
        "error": (result.get("error") or "")[:500],
    })


def submit_job(prompt: str, timeout: int, session: str) -> dict:
    job_id = uuid.uuid4().hex[:12]
    job = {
        "job_id": job_id,
        "status": "queued",
        "session": session or "",
        "prompt_preview": prompt[:200],
        "submitted_at": time.time(),
    }
    _record_job(job)

    _active_delta(1)
    publish_state(busy="true", status="running", last_source="api")

    thread = threading.Thread(
        target=_run_job, args=(job_id, prompt, timeout, session), daemon=True
    )
    thread.start()
    return job


class AutomationApiHandler(http.server.BaseHTTPRequestHandler):
    server_token: str = ""

    def log_message(self, format_str, *args):
        """Override standard HTTP log format for cleaner output."""
        logger.info(f"{self.address_string()} - {format_str % args}")

    def send_json_response(self, status_code: int, data: dict):
        """Send a JSON HTTP response."""
        response_bytes = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(response_bytes)))
        self.end_headers()
        self.wfile.write(response_bytes)

    def verify_auth(self) -> bool:
        """Verify API key from X-API-Key or Authorization header."""
        if not self.server_token:
            # If no token is configured, reject for security
            return False
            
        auth_header = self.headers.get("Authorization", "")
        api_key_header = self.headers.get("X-API-Key", "")
        
        token = ""
        if api_key_header:
            token = api_key_header.strip()
        elif auth_header.startswith("Bearer "):
            token = auth_header[7:].strip()
            
        return secrets_equal(token, self.server_token)

    def do_GET(self):
        """Health check, and reading back async jobs."""
        client_ip = self.client_address[0]
        if not is_trusted_ip(client_ip):
            logger.warning(f"Rejected GET request from untrusted IP: {client_ip}")
            self.send_json_response(403, {"error": "Forbidden: Client IP not allowed"})
            return

        if self.path in ("/health", "/api/health", "/"):
            claude_path = get_claude_binary_path()
            claude_ok = os.path.isfile(claude_path) and os.access(claude_path, os.X_OK)

            self.send_json_response(200, {
                "status": "ok",
                "service": "claude-automation-api",
                "claude_binary": claude_path,
                "claude_available": claude_ok
            })
            return

        # Job status. Authenticated, because a job holds the prompt an
        # automation sent and the answer Claude gave -- which is exactly the
        # content the token exists to protect. The health endpoint above is
        # deliberately open (it reveals nothing) and this is deliberately not.
        if self.path == "/api/jobs" or self.path.startswith("/api/jobs/"):
            if not check_rate_limit(client_ip, bucket="poll", limit=MAX_POLL_REQUESTS_PER_MINUTE):
                self.send_json_response(429, {"error": "Too Many Requests: Slow down job polling"})
                return
            if not self.verify_auth():
                logger.warning(f"Unauthorized GET {self.path} from {client_ip}")
                self.send_json_response(401, {"error": "Unauthorized: Invalid or missing API key"})
                return

            if self.path == "/api/jobs":
                self.send_json_response(200, {"jobs": list_jobs()})
                return

            job_id = self.path[len("/api/jobs/"):].strip("/")
            job = get_job(job_id)
            if job is None:
                # Retention is finite and in memory, so "unknown" genuinely
                # cannot be distinguished from "evicted" or "lost to a restart".
                # Say so, rather than implying the job never existed.
                self.send_json_response(404, {
                    "error": "No such job. Jobs are kept in memory, capped at "
                             f"{MAX_TRACKED_JOBS}, and are lost when the add-on restarts.",
                })
                return
            self.send_json_response(200, job)
            return

        self.send_json_response(404, {"error": "Endpoint not found"})

    def do_POST(self):
        """Handle POST requests (run prompt)."""
        client_ip = self.client_address[0]
        
        # 1. IP Whitelist check
        if not is_trusted_ip(client_ip):
            logger.warning(f"Rejected POST request from untrusted IP: {client_ip}")
            self.send_json_response(403, {"error": "Forbidden: Client IP not allowed"})
            return

        # 2. Rate limit check.
        #
        # This runs BEFORE authentication on purpose. With the order reversed,
        # failed auth never reached the limiter, so the token could be
        # brute-forced at line speed from any co-resident add-on on the Docker
        # bridge -- every attempt got a clean 401 and the limiter only ever saw
        # requests that had already presented the correct token.
        if not check_rate_limit(client_ip):
            logger.warning(f"Rate limit exceeded for {client_ip}")
            self.send_json_response(429, {"error": "Too Many Requests: Rate limit exceeded (max 10/min)"})
            return

        # 3. Authentication check
        if not self.verify_auth():
            logger.warning(f"Unauthorized POST request to {self.path} from {client_ip}")
            self.send_json_response(401, {"error": "Unauthorized: Invalid or missing API key"})
            return

        # 4. Path check
        if self.path not in ("/api/prompt", "/prompt"):
            self.send_json_response(404, {"error": "Endpoint not found"})
            return

        # 5. Payload size check
        content_length_str = self.headers.get("Content-Length", "0")
        try:
            content_length = int(content_length_str)
        except ValueError:
            self.send_json_response(400, {"error": "Invalid Content-Length header"})
            return

        if content_length > MAX_PAYLOAD_BYTES:
            self.send_json_response(413, {"error": f"Payload Too Large: Exceeds {MAX_PAYLOAD_BYTES} bytes"})
            return

        # Read body
        try:
            body_bytes = self.rfile.read(content_length)
            payload = json.loads(body_bytes.decode("utf-8"))
        except Exception as e:
            self.send_json_response(400, {"error": f"Invalid JSON payload: {str(e)}"})
            return

        # A body that parses but is not an object (a list, a bare string, a
        # number) reached .get() and raised, answering 500 with a traceback in
        # the log for what is plainly a malformed request.
        if not isinstance(payload, dict):
            self.send_json_response(400, {"error": "Payload must be a JSON object"})
            return

        prompt = payload.get("prompt")
        if not isinstance(prompt, str):
            self.send_json_response(400, {"error": "Field 'prompt' must be a string"})
            return
        prompt = prompt.strip()
        if not prompt:
            self.send_json_response(400, {"error": "Missing or empty 'prompt' field in payload"})
            return

        timeout = payload.get("timeout", DEFAULT_TIMEOUT_SECONDS)
        try:
            timeout = min(max(int(timeout), 5), MAX_TIMEOUT_SECONDS)
        except (ValueError, TypeError):
            timeout = DEFAULT_TIMEOUT_SECONDS

        # Session names end up in a filename-free mapping but are echoed into
        # events and logs, so keep them boring.
        session = str(payload.get("session", "") or "").strip()
        if session and not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session):
            self.send_json_response(400, {
                "error": "Invalid 'session': use up to 64 letters, digits, - or _"
            })
            return

        run_async = bool(payload.get("async", False))

        # Asynchronous: answer now, work later.
        #
        # This is the mode Home Assistant actually needs. rest_command gives up
        # after 10 seconds unless told otherwise, and a prompt worth automating
        # rarely finishes in ten seconds, so the synchronous path silently
        # failed for most real uses while appearing to work in testing.
        if run_async:
            job = submit_job(prompt, timeout, session)
            logger.info(f"Queued async job {job['job_id']} from {client_ip}")
            self.send_json_response(202, {
                "job_id": job["job_id"],
                "status": job["status"],
                "session": job["session"],
                "poll_url": f"/api/jobs/{job['job_id']}",
                "event": JOB_FINISHED_EVENT,
                "note": "Result arrives as the Home Assistant event "
                        f"{JOB_FINISHED_EVENT}, or poll poll_url.",
            })
            return

        # 6. Execute Claude prompt non-interactively with serialization lock
        logger.info(f"Received prompt from {client_ip} (len={len(prompt)}, timeout={timeout}s)")
        
        acquired = EXECUTION_LOCK.acquire(blocking=True, timeout=10.0)
        if not acquired:
            self.send_json_response(503, {"error": "Service Busy: Another Claude prompt is currently executing"})
            return

        start_time = time.time()
        publish_state(busy="true", status="running", last_source="api")
        try:
            result = run_claude_prompt(prompt, timeout=timeout, session=session)
            duration = time.time() - start_time
            result["duration_seconds"] = round(duration, 2)

            publish_state(
                busy="false",
                status="idle",
                last_result="ok" if result.get("success") else "error",
                last_source="api",
                last_run=time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
            )

            status_code = 200 if result.get("success") else 500
            self.send_json_response(status_code, result)
        finally:
            EXECUTION_LOCK.release()


def secrets_equal(val1: str, val2: str) -> bool:
    """Constant-time string comparison to prevent timing attacks.

    hmac.compare_digest rather than a hand-rolled loop: the previous version
    returned early on a length mismatch and compared character by character in
    interpreted Python, so it leaked the token length and was not actually
    constant-time.
    """
    return hmac.compare_digest(val1.encode("utf-8"), val2.encode("utf-8"))


def _looks_like_stale_session(stderr: str) -> bool:
    """Does this stderr say the session could not be resumed?

    Matched on text because Claude Code has no distinct exit code for it. Kept
    deliberately narrow: a broad match would turn every failure into a silent
    "start over", which would lose the conversation the caller asked to keep.
    """
    lowered = (stderr or "").lower()
    return any(phrase in lowered for phrase in (
        "no conversation found",
        "session not found",
        "no such session",
        "could not resume",
    ))


def run_claude_prompt(prompt: str, timeout: int = DEFAULT_TIMEOUT_SECONDS,
                      session: str = "", _deadline: float = 0.0) -> dict:
    """Run `claude -p "<prompt>"` in a clean, controlled environment.

    With `session`, the prompt joins a named conversation that persists across
    calls: the first call creates a Claude session, later ones resume it. That
    is what lets an automation follow up on its own earlier question instead of
    re-explaining the house every time.
    """
    claude_bin = get_claude_binary_path()
    options = load_addon_options()

    # The caller's timeout is a budget for the whole call, not per attempt. The
    # stale-session retry below re-enters this function, and without a shared
    # deadline it started a SECOND full timeout -- so a caller asking for the
    # 300s maximum could be held for 600s, while holding EXECUTION_LOCK and
    # blocking every other prompt for the duration.
    if not _deadline:
        _deadline = time.time() + timeout
    timeout = max(5, int(min(timeout, _deadline - time.time())))

    cmd = [claude_bin, "-p", prompt]

    session_uuid = ""
    session_is_new = False
    if session:
        session_uuid, session_is_new = session_id_for(session)
        # --session-id names a NEW session; --resume continues one that exists.
        # Using the wrong one of the two is an error rather than a fallback, so
        # which call this is has to be tracked here.
        cmd += (["--session-id", session_uuid] if session_is_new
                else ["--resume", session_uuid])

    # Add optional flags from add-on options
    if options.get("dangerously_skip_permissions") is True:
        cmd.append("--dangerously-skip-permissions")

    # `or ""`: an option present but null in options.json yields None here, and
    # None.strip() would raise inside the request handler.
    extra_args = (options.get("claude_extra_args") or "").strip()
    if extra_args:
        try:
            cmd.extend(shlex.split(extra_args))
        except Exception as e:
            logger.warning(f"Could not parse claude_extra_args '{extra_args}': {e}")

    # Setup environment
    data_home = "/data/home"
    env = dict(os.environ)
    env["HOME"] = data_home
    env["XDG_CONFIG_HOME"] = "/data/.config"
    env["XDG_CACHE_HOME"] = "/data/.cache"
    env["XDG_STATE_HOME"] = "/data/.local/state"
    env["XDG_DATA_HOME"] = "/data/.local/share"
    env["ANTHROPIC_CONFIG_DIR"] = "/data/.config/claude"
    env["ANTHROPIC_HOME"] = "/data"
    env["PATH"] = f"{data_home}/.local/bin:{env.get('PATH', '')}"
    env["IS_SANDBOX"] = "1"

    # Claude Code's Stop hook fires for `-p` runs too. Without this every
    # automation-triggered prompt would ALSO raise the interactive "Claude
    # finished" notification, on top of whatever the automation itself reports.
    env["CLAUDE_TERMINAL_NO_HOOK_NOTIFY"] = "1"

    work_dir = "/config" if os.path.isdir("/config") else data_home

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=work_dir,
            env=env
        )

        stdout_str = proc.stdout.strip() if proc.stdout else ""
        stderr_str = proc.stderr.strip() if proc.stderr else ""

        if proc.returncode == 0:
            return {
                "success": True,
                "response": stdout_str,
                "exit_code": 0,
                "session": session,
            }

        # A resume that fails because the session is gone is recoverable and
        # common: Claude Code prunes old sessions, and /data can be restored
        # from a backup that predates the mapping file. Dropping the mapping and
        # starting a fresh conversation once is far better than answering 500
        # forever to an automation whose only fault is having been quiet for a
        # while. Only ever retried once, and only for a resume.
        if session and not session_is_new and _looks_like_stale_session(stderr_str):
            logger.info(f"Session '{session}' could not be resumed; starting a new one")
            forget_session(session)
            # Whatever is left of the original budget, never a fresh one.
            remaining = _deadline - time.time()
            if remaining < 5:
                return {
                    "success": False,
                    "response": stdout_str,
                    "error": "Session could not be resumed and there was no time left to retry",
                    "exit_code": proc.returncode,
                    "session": session,
                }
            return run_claude_prompt(prompt, timeout=timeout, session=session,
                                     _deadline=_deadline)

        return {
            "success": False,
            "response": stdout_str,
            "error": stderr_str or f"Claude exited with return code {proc.returncode}",
            "exit_code": proc.returncode,
            "session": session,
        }

    except subprocess.TimeoutExpired:
        logger.error(f"Claude prompt timed out after {timeout} seconds")
        return {
            "success": False,
            "error": f"Execution timed out after {timeout} seconds",
            "exit_code": -1
        }
    except Exception as e:
        logger.error(f"Failed to execute claude prompt: {e}")
        return {
            "success": False,
            "error": str(e),
            "exit_code": -1
        }


def read_api_token(token_file: str, static_key: str = "") -> str:
    """Read API token from file or options."""
    if static_key and static_key.strip():
        return static_key.strip()

    if os.path.isfile(token_file):
        try:
            with open(token_file, "r", encoding="utf-8") as f:
                token = f.read().strip()
                if token:
                    return token
        except Exception as e:
            logger.warning(f"Could not read token file {token_file}: {e}")

    logger.error(f"No API token available in {token_file} or options. Server authentication will fail.")
    return ""


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Threaded HTTP server to handle health checks while a prompt is processing."""
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description="Claude Terminal Automation API Server")
    parser.add_argument("--port", type=int, default=8128, help="Port to listen on (default: 8128)")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="Host address to bind to (default: 0.0.0.0)")
    parser.add_argument("--token-file", type=str, default="/data/automation_api_token", help="Path to API token file")
    parser.add_argument("--token", type=str, default="", help="Static API key")

    args = parser.parse_args()

    token = read_api_token(args.token_file, static_key=args.token)
    if not token:
        logger.error("API Token is empty. Refusing to start server without authentication.")
        sys.exit(1)

    AutomationApiHandler.server_token = token

    server_address = (args.host, args.port)
    try:
        httpd = ThreadedHTTPServer(server_address, AutomationApiHandler)
        logger.info(f"Claude Automation API Server running on {args.host}:{args.port}")
        logger.info("Security controls active: Token Auth, Local IP Filtering, Rate Limits, Process Mutex.")
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down API server...")
    except Exception as e:
        logger.error(f"Failed to start API server: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
