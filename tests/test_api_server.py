#!/usr/bin/env python3
"""
Unit tests for claude-api-server.py
"""

import json
import logging
import os
import sys
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
        # Reset rate limit state for test_ip
        with api_server.RATE_LIMIT_LOCK:
            api_server.IP_REQUEST_TIMES[test_ip] = []

        # Allow up to MAX_REQUESTS_PER_MINUTE
        for _ in range(api_server.MAX_REQUESTS_PER_MINUTE):
            self.assertTrue(api_server.check_rate_limit(test_ip))

        # Next request should be rate limited
        self.assertFalse(api_server.check_rate_limit(test_ip))

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
        # Each test starts with a clean rate-limit budget for loopback.
        with api_server.RATE_LIMIT_LOCK:
            api_server.IP_REQUEST_TIMES["127.0.0.1"] = []

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

    def test_health_endpoint(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=10) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(json.loads(resp.read())["status"], "ok")


if __name__ == "__main__":
    unittest.main()
