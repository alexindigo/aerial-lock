#!/usr/bin/env python3
"""Driver waits evaluate their condition after observing the exit they react to.

Deterministic fakes reproduce the race: output (or state) that becomes
available between the last scan and the exit observation must still count.
"""
from collections import deque
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("remediation_driver",
                                             Path(__file__).with_name("remediation-driver.py"))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def exited_process_with_late_line(line):
    """An exited process whose reader appends its last line only while it is joined."""
    observed = driver.ObservedProcess.__new__(driver.ObservedProcess)
    observed.lines = deque()
    observed.log = Path("fake.log")
    observed.process = SimpleNamespace(poll=lambda: 0)
    observed.thread = SimpleNamespace(join=lambda timeout=None: observed.lines.append((1, line)))
    return observed


class WaitOrder(unittest.TestCase):
    def test_wait_line_sees_a_line_printed_just_before_exit(self):
        observed = exited_process_with_late_line("ext_session_lock_v1#35.unlock_and_destroy()\n")
        self.assertEqual(observed.wait_line(lambda line: "unlock_and_destroy" in line, 1), 1)

    def test_wait_line_still_fails_when_the_line_never_came(self):
        observed = exited_process_with_late_line("unrelated\n")
        with self.assertRaisesRegex(RuntimeError, "NOT_EXERCISED"):
            observed.wait_line(lambda line: "unlock_and_destroy" in line, 1)

    def test_panel_snapshot_sees_a_snapshot_printed_just_before_exit(self):
        session = driver.Session.__new__(driver.Session)
        session.locker = exited_process_with_late_line('PANEL_SNAPSHOT {"output": "A"}\n')
        self.assertEqual(session.panel_snapshot(lambda s: s["output"] == "A", seconds=1), {"output": "A"})

    def test_hyprland_outputs_are_read_after_the_locker_exit_is_seen(self):
        polls = []
        session = driver.Session.__new__(driver.Session)
        session.locker = SimpleNamespace(process=SimpleNamespace(poll=lambda: polls.append(1) or 0))
        # The compositor reaches the expected set at the moment the exit is observed.
        session.hypr = lambda *args: '[{"name": "B", "width": 1280}]' if polls else '[{"name": "A", "width": 1280}]'
        self.assertEqual(session.wait_hypr_outputs({"B"}, seconds=1), {"B"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
