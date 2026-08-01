#!/usr/bin/env python3
"""
Unit tests for claude-api-server.py
"""

import os
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()
