#!/usr/bin/env python3
"""
Unit tests for claude-api-server.py
"""

import json
import logging
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

# Add scripts directory to module search path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../claude-terminal/scripts")))

import importlib.util

spec = importlib.util.spec_from_file_location(
    "claude_api_server",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "../claude-terminal/scripts/claude-api-server.py"))
)
api_server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api_server)


class TestAPIServerUtils(unittest.TestCase):
    """Test utility functions in claude-api-server.py."""

    def test_is_trusted_ip(self):
        self.assertTrue(api_server.is_trusted_ip("127.0.0.1"))
        self.assertTrue(api_server.is_trusted_ip("::1"))
        self.assertTrue(api_server.is_trusted_ip("localhost"))
        self.assertTrue(api_server.is_trusted_ip("10.0.0.5"))
        self.assertTrue(api_server.is_trusted_ip("172.30.32.1"))
        self.assertTrue(api_server.is_trusted_ip("192.168.1.100"))
        self.assertFalse(api_server.is_trusted_ip("8.8.8.8"))
        self.assertFalse(api_server.is_trusted_ip("1.1.1.1"))

    def test_check_rate_limit(self):
        test_ip = "192.168.99.99"
        # Buckets are keyed "<bucket>:<ip>", so clearing by bare IP would leave
        # the real key populated and make this depend on test ordering.
        with api_server.RATE_LIMIT_LOCK:
            api_server.IP_REQUEST_TIMES.clear()

        # Allow up to MAX_REQUESTS_PER_MINUTE
        for _ in range(api_server.MAX_REQUESTS_PER_MINUTE):
            self.assertTrue(api_server.check_rate_limit(test_ip))

        # Next request should be rate limited
        self.assertFalse(api_server.check_rate_limit(test_ip))

    def test_rate_limit_buckets_are_independent(self):
        """Polling a job must not spend the budget for starting one.

        Sharing one bucket made async jobs unusable: an automation that checks
        its job every few seconds exhausts the 10/min prompt allowance and can
        then no longer read its own result.
        """
        test_ip = "192.168.99.98"
        with api_server.RATE_LIMIT_LOCK:
            api_server.IP_REQUEST_TIMES.clear()

        for _ in range(api_server.MAX_REQUESTS_PER_MINUTE):
            self.assertTrue(api_server.check_rate_limit(test_ip))
        self.assertFalse(api_server.check_rate_limit(test_ip))

        # The poll bucket is untouched by the exhausted run bucket.
        self.assertTrue(api_server.check_rate_limit(
            test_ip, bucket="poll", limit=api_server.MAX_POLL_REQUESTS_PER_MINUTE))

    def test_stale_session_detection_is_narrow(self):
        """Only a genuine "cannot resume" may trigger a fresh conversation.

        A broad match would turn every failure into a silent start-over, losing
        exactly the conversation the caller asked to keep.
        """
        for stderr in ("No conversation found with session ID abc",
                       "Session not found",
                       "Could not resume the session"):
            self.assertTrue(api_server._looks_like_stale_session(stderr))

        for stderr in ("", "Permission denied", "API error: overloaded",
                       "Error: file not found"):
            self.assertFalse(api_server._looks_like_stale_session(stderr))

    def test_named_sessions_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            original = api_server.SESSIONS_FILE
            api_server.SESSIONS_FILE = os.path.join(tmp, "sessions.json")
            try:
                first, is_new = api_server.session_id_for("doorbell")
                self.assertTrue(is_new)

                # The second call must resume, not create: passing --session-id
                # for an existing session is an error, not a no-op.
                again, is_new_again = api_server.session_id_for("doorbell")
                self.assertEqual(first, again)
                self.assertFalse(is_new_again)

                other, _ = api_server.session_id_for("energy")
                self.assertNotEqual(first, other)

                api_server.forget_session("doorbell")
                after, is_new_after = api_server.session_id_for("doorbell")
                self.assertTrue(is_new_after)
                self.assertNotEqual(first, after)
            finally:
                api_server.SESSIONS_FILE = original

    def test_job_registry_is_capped(self):
        """Jobs are held in memory, so the cap is the only thing bounding it."""
        with api_server.JOBS_LOCK:
            api_server.JOBS.clear()

        for i in range(api_server.MAX_TRACKED_JOBS + 10):
            api_server._record_job({"job_id": f"job{i}", "status": "queued"})

        self.assertEqual(len(api_server.JOBS), api_server.MAX_TRACKED_JOBS)
        # Oldest evicted first, newest kept.
        self.assertIsNone(api_server.get_job("job0"))
        self.assertIsNotNone(
            api_server.get_job(f"job{api_server.MAX_TRACKED_JOBS + 9}"))

    def test_get_claude_binary_path(self):
        path = api_server.get_claude_binary_path()
        self.assertIsInstance(path, str)
        self.assertTrue(len(path) > 0)

    def test_secrets_equal(self):
        self.assertTrue(api_server.secrets_equal("abc123", "abc123"))
        self.assertFalse(api_server.secrets_equal("abc123", "abc124"))
        # Different lengths must compare unequal, not raise.
        self.assertFalse(api_server.secrets_equal("abc", "abcdef"))
        self.assertFalse(api_server.secrets_equal("", "abc"))


TOKEN = "unit-test-token"


class TestAPIServerRequests(unittest.TestCase):
    """End-to-end checks against a live server on loopback."""

    @classmethod
    def setUpClass(cls):
        # The server logs every request; keep the test output readable.
        logging.disable(logging.CRITICAL)
        api_server.AutomationApiHandler.server_token = TOKEN
        cls.httpd = api_server.ThreadedHTTPServer(("127.0.0.1", 0), api_server.AutomationApiHandler)
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        logging.disable(logging.NOTSET)

    def setUp(self):
        # Each test starts with a clean rate-limit budget. Buckets are keyed
        # "<bucket>:<ip>", so clearing the whole map is the only reliable reset.
        with api_server.RATE_LIMIT_LOCK:
            api_server.IP_REQUEST_TIMES.clear()

    def _request(self, path, token=TOKEN, payload=None, method="POST"):
        """Return (status, parsed body) rather than just the status code."""
        data = None
        if payload is not None or method == "POST":
            data = json.dumps(payload if payload is not None else {"prompt": "x"}).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=data,
            headers={"Content-Type": "application/json", "X-API-Key": token},
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read() or b"{}")
            except Exception:
                return e.code, {}

    def _post(self, path, token=TOKEN, payload=None):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=json.dumps(payload if payload is not None else {"prompt": "x"}).encode(),
            headers={"Content-Type": "application/json", "X-API-Key": token},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status
        except urllib.error.HTTPError as e:
            return e.code

    def test_prompt_path_is_routed(self):
        # The handler runs claude, which is absent here, so it answers 500 --
        # what matters is that the route exists at all.
        self.assertNotEqual(self._post("/api/prompt"), 404)

    def test_unrouted_paths_404(self):
        # /api/query is the path claude-bot and the blueprint used to call.
        self.assertEqual(self._post("/api/query"), 404)

    def test_bad_token_is_rejected(self):
        self.assertEqual(self._post("/api/prompt", token="wrong"), 401)

    def test_failed_auth_is_rate_limited(self):
        # Regression: the rate-limit check used to run AFTER authentication, so
        # a wrong token could be retried without limit.
        codes = [
            self._post("/api/prompt", token=f"wrong-{i}")
            for i in range(api_server.MAX_REQUESTS_PER_MINUTE + 5)
        ]
        self.assertIn(429, codes, "brute-forcing the token was never rate limited")
        self.assertEqual(codes[-1], 429)

    def test_async_submission_answers_immediately(self):
        """The mode Home Assistant actually needs.

        rest_command gives up after 10 seconds by default; a useful prompt takes
        longer. 202 with a job id is what makes the call survivable.
        """
        status, body = self._request(
            "/api/prompt", payload={"prompt": "hello", "async": True})
        self.assertEqual(status, 202)
        self.assertIn("job_id", body)
        self.assertEqual(body["event"], api_server.JOB_FINISHED_EVENT)
        self.assertEqual(body["poll_url"], f"/api/jobs/{body['job_id']}")

        # The job is readable straight away, before it has finished.
        status, job = self._request(f"/api/jobs/{body['job_id']}", method="GET")
        self.assertEqual(status, 200)
        self.assertEqual(job["job_id"], body["job_id"])

    def test_job_endpoints_require_authentication(self):
        """A job holds the prompt sent and the answer given -- exactly what the
        token exists to protect. Only /health is deliberately open."""
        status, _ = self._request("/api/jobs", token="wrong", method="GET")
        self.assertEqual(status, 401)
        status, _ = self._request("/api/jobs/whatever", token="wrong", method="GET")
        self.assertEqual(status, 401)

    def test_unknown_job_explains_retention(self):
        status, body = self._request("/api/jobs/does-not-exist", method="GET")
        self.assertEqual(status, 404)
        # "Unknown" cannot be distinguished from "evicted" or "lost to a
        # restart", so the message must not imply the job never existed.
        self.assertIn("restart", body.get("error", "").lower())

    def test_job_listing_omits_response_bodies(self):
        status, body = self._request(
            "/api/prompt", payload={"prompt": "hello", "async": True})
        self.assertEqual(status, 202)

        status, listing = self._request("/api/jobs", method="GET")
        self.assertEqual(status, 200)
        self.assertTrue(listing["jobs"])
        for job in listing["jobs"]:
            self.assertNotIn("response", job)

    def test_bad_session_name_is_rejected(self):
        status, _ = self._request(
            "/api/prompt", payload={"prompt": "x", "session": "../escape"})
        self.assertEqual(status, 400)
        status, _ = self._request(
            "/api/prompt", payload={"prompt": "x", "session": "a" * 65})
        self.assertEqual(status, 400)

    def test_health_endpoint(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=10) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(json.loads(resp.read())["status"], "ok")


if __name__ == "__main__":
    unittest.main()
