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
"""

import argparse
import http.server
import json
import logging
import os
import shlex
import socketserver
import subprocess
import sys
import threading
import time
from typing import Dict, List, Tuple

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
DEFAULT_TIMEOUT_SECONDS = 120
MAX_TIMEOUT_SECONDS = 300


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


def check_rate_limit(ip_str: str) -> bool:
    """Enforce rate limiting per IP address. Returns True if allowed, False if exceeded."""
    now = time.time()
    cutoff = now - 60.0
    
    with RATE_LIMIT_LOCK:
        times = IP_REQUEST_TIMES.get(ip_str, [])
        # Prune old timestamps
        times = [t for t in times if t > cutoff]
        
        if len(times) >= MAX_REQUESTS_PER_MINUTE:
            IP_REQUEST_TIMES[ip_str] = times
            return False
            
        times.append(now)
        IP_REQUEST_TIMES[ip_str] = times
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
        """Handle GET requests (health check)."""
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
        else:
            self.send_json_response(404, {"error": "Endpoint not found"})

    def do_POST(self):
        """Handle POST requests (run prompt)."""
        client_ip = self.client_address[0]
        
        # 1. IP Whitelist check
        if not is_trusted_ip(client_ip):
            logger.warning(f"Rejected POST request from untrusted IP: {client_ip}")
            self.send_json_response(403, {"error": "Forbidden: Client IP not allowed"})
            return

        # 2. Authentication check
        if not self.verify_auth():
            logger.warning(f"Unauthorized POST request to {self.path} from {client_ip}")
            self.send_json_response(401, {"error": "Unauthorized: Invalid or missing API key"})
            return

        # 3. Path check
        if self.path not in ("/api/prompt", "/prompt"):
            self.send_json_response(404, {"error": "Endpoint not found"})
            return

        # 4. Rate limit check
        if not check_rate_limit(client_ip):
            logger.warning(f"Rate limit exceeded for {client_ip}")
            self.send_json_response(429, {"error": "Too Many Requests: Rate limit exceeded (max 10/min)"})
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

        prompt = payload.get("prompt", "").strip()
        if not prompt:
            self.send_json_response(400, {"error": "Missing or empty 'prompt' field in payload"})
            return

        timeout = payload.get("timeout", DEFAULT_TIMEOUT_SECONDS)
        try:
            timeout = min(max(int(timeout), 5), MAX_TIMEOUT_SECONDS)
        except (ValueError, TypeError):
            timeout = DEFAULT_TIMEOUT_SECONDS

        # 6. Execute Claude prompt non-interactively with serialization lock
        logger.info(f"Received prompt from {client_ip} (len={len(prompt)}, timeout={timeout}s)")
        
        acquired = EXECUTION_LOCK.acquire(blocking=True, timeout=10.0)
        if not acquired:
            self.send_json_response(503, {"error": "Service Busy: Another Claude prompt is currently executing"})
            return

        start_time = time.time()
        try:
            result = run_claude_prompt(prompt, timeout=timeout)
            duration = time.time() - start_time
            result["duration_seconds"] = round(duration, 2)
            
            status_code = 200 if result.get("success") else 500
            self.send_json_response(status_code, result)
        finally:
            EXECUTION_LOCK.release()


def secrets_equal(val1: str, val2: str) -> bool:
    """Constant-time string comparison to prevent timing attacks."""
    if len(val1) != len(val2):
        return False
    result = 0
    for c1, c2 in zip(val1, val2):
        result |= ord(c1) ^ ord(c2)
    return result == 0


def run_claude_prompt(prompt: str, timeout: int = DEFAULT_TIMEOUT_SECONDS) -> dict:
    """Run `claude -p "<prompt>"` in a clean, controlled environment."""
    claude_bin = get_claude_binary_path()
    options = load_addon_options()

    cmd = [claude_bin, "-p", prompt]

    # Add optional flags from add-on options
    if options.get("dangerously_skip_permissions") is True:
        cmd.append("--dangerously-skip-permissions")

    extra_args = options.get("claude_extra_args", "").strip()
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
                "exit_code": 0
            }
        else:
            return {
                "success": False,
                "response": stdout_str,
                "error": stderr_str or f"Claude exited with return code {proc.returncode}",
                "exit_code": proc.returncode
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
