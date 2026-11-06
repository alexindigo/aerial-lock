#!/usr/bin/env python3
"""Failure-path teardown contract, using no compositor, daemon or credential."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("surface_driver", Path(__file__).with_name("surface-input-integration.py"))
surface = importlib.util.module_from_spec(spec)
spec.loader.exec_module(surface)


class Teardown(unittest.TestCase):
    def test_cleanup_error_still_stops_ime_and_reports_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            first = RuntimeError("session cleanup failed")
            session = SimpleNamespace(output=Path(directory),
                owned=SimpleNamespace(record={"current_source_identity": "synthetic"}), locker=None,
                start=Mock(side_effect=ValueError("body failed")), cleanup=Mock(side_effect=first))
            ime = SimpleNamespace(stop=Mock(side_effect=RuntimeError("IME stop also failed")))
            stdout = io.StringIO()
            with patch.object(surface.driver, "Session", return_value=session), \
                 patch.object(surface, "PrivateIme", return_value=ime), \
                 patch.object(sys, "argv", ["surface-input-integration.py", "--root", directory,
                     "--vm-record", str(Path(directory) / "owned.json"), "--case", "compose"]), \
                 contextlib.redirect_stdout(stdout), self.assertRaises(RuntimeError) as raised:
                surface.main()
            self.assertIs(raised.exception, first)
            ime.stop.assert_called_once_with()
            result = json.loads((Path(directory) / "surface-input.json").read_text())
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual([entry["step"] for entry in result["teardown_errors"]], ["session.cleanup", "ime.stop"])
            self.assertEqual(json.loads(stdout.getvalue())["status"], "FAIL")

    def test_daemon_wait_error_still_terminates_and_waits_for_bus(self):
        first = RuntimeError("daemon wait failed")
        daemon = SimpleNamespace(process=Mock(), finish=Mock(side_effect=first))
        daemon.process.poll.return_value = None
        bus = Mock()
        bus.poll.return_value = None
        bus.terminate.side_effect = RuntimeError("bus termination also failed")
        ime = surface.PrivateIme(None)
        ime.daemon, ime.bus = daemon, bus
        with self.assertRaises(RuntimeError) as raised:
            ime.stop()
        self.assertIs(raised.exception, first)
        daemon.process.terminate.assert_called_once_with()
        bus.terminate.assert_called_once_with()
        bus.wait.assert_called_once_with(timeout=5)
        self.assertEqual([entry["step"] for entry in ime.teardown_errors], ["fcitx.wait", "bus.terminate"])

    def test_successful_stop_waits_for_both_owned_processes(self):
        daemon = SimpleNamespace(process=Mock(), finish=Mock())
        daemon.process.poll.return_value = None
        bus = Mock()
        bus.poll.return_value = None
        ime = surface.PrivateIme(None)
        ime.daemon, ime.bus = daemon, bus
        ime.stop()
        daemon.finish.assert_called_once_with(5)
        bus.wait.assert_called_once_with(timeout=5)


if __name__ == "__main__":
    unittest.main()
