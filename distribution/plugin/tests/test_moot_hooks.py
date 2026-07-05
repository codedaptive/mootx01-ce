"""Tests for moot_hooks.py — is_daemon_reachable() coverage.

Run with:
    python3 -m unittest discover -s distribution/plugin/tests -p "test_*.py"
or (no pytest needed):
    python3 -m unittest distribution.plugin.tests.test_moot_hooks

All tests use unittest.mock. is_daemon_reachable() imports socket inside
the function body, so we patch socket.create_connection at the stdlib
socket module level.
"""
import sys
import os
import socket as _socket_module
import unittest
from unittest.mock import patch, MagicMock

# Make the hooks directory importable without installing anything.
_HOOKS_DIR = os.path.join(os.path.dirname(__file__), "..", "hooks")
sys.path.insert(0, os.path.abspath(_HOOKS_DIR))

import moot_hooks  # noqa: E402


class TestIsDaemonReachable(unittest.TestCase):
    """is_daemon_reachable() — mock-based coverage of all paths."""

    def test_unreachable_returns_false(self):
        """When create_connection raises, the function returns False silently."""
        with patch.object(_socket_module, "create_connection",
                          side_effect=OSError("connection refused")):
            result = moot_hooks.is_daemon_reachable()
        self.assertFalse(result, "unreachable daemon must return False")

    def test_reachable_returns_true(self):
        """When create_connection succeeds (context manager), the function returns True."""
        mock_conn = MagicMock()
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)
        with patch.object(_socket_module, "create_connection",
                          return_value=mock_conn):
            result = moot_hooks.is_daemon_reachable()
        self.assertTrue(result, "reachable daemon must return True")

    def test_timeout_returns_false(self):
        """socket.timeout is caught — function returns False, not raise."""
        with patch.object(_socket_module, "create_connection",
                          side_effect=_socket_module.timeout("timed out")):
            result = moot_hooks.is_daemon_reachable()
        self.assertFalse(result, "timeout must return False, not raise")

    def test_custom_port_forwarded(self):
        """The port kwarg is forwarded to socket.create_connection."""
        with patch.object(_socket_module, "create_connection",
                          side_effect=OSError) as mock_conn:
            moot_hooks.is_daemon_reachable(port=9999)
        mock_conn.assert_called_once()
        args, _ = mock_conn.call_args
        host_port = args[0]
        self.assertEqual(host_port[1], 9999,
                         "custom port must be forwarded to socket.create_connection")


class TestModeStopUnreachable(unittest.TestCase):
    """mode_stop() exits early (silent, exit-0 semantics) when daemon is unreachable.

    The hook must not print any JSON decision when the daemon is down.
    Blocking on an unreachable daemon surfaces an MCP-not-connected error
    the user cannot act on.
    """

    def test_mode_stop_silent_when_daemon_unreachable(self):
        """mode_stop must not call print() when is_daemon_reachable() returns False."""
        printed = []

        def capturing_print(*args, **kwargs):
            printed.append(args)

        with patch("moot_hooks.is_daemon_reachable", return_value=False), \
             patch("builtins.print", side_effect=capturing_print):
            moot_hooks.mode_stop({"session_id": "test-unreachable"})

        self.assertEqual(
            printed, [],
            "mode_stop must not print anything when daemon is unreachable"
        )


if __name__ == "__main__":
    unittest.main()
