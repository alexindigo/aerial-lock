#!/usr/bin/env python3
"""Backend-policy regression only. Full locker/PAM/output tests remain separate."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("remediation_driver",
                                             Path(__file__).with_name("remediation-driver.py"))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def snapshot(output, attached=True, preserved=True, focused=True):
    return {"output": output, "attached": attached, "focused": focused,
            "hasVideo": attached, "backdropSameWindow": attached,
            "syntheticDraft": True, "writer": 2 if preserved else 3,
            "revision": 27, "cursor": 21, "anchor": 24}


def same_editor(state):
    return state["syntheticDraft"] and state["writer"] == 2 and state["revision"] == 27 \
        and state["cursor"] == 21 and state["anchor"] == 24


class Fixture(driver.Session):
    def __init__(self, backend, intermediate, restored=None):
        self.args = SimpleNamespace(backend=backend)
        self.intermediate = intermediate
        self.restored = restored or snapshot("recovery")
        self.phase = "initial"
        self.operations = []

    def disable(self):
        self.operations.append("disable")
        self.phase = "intermediate"

    def add(self):
        self.operations.append("add")
        self.phase = "restored"

    def wait_hypr_outputs(self, expected, seconds=10):
        actual = {self.intermediate["output"]} if self.phase == "intermediate" else {self.restored["output"]}
        if actual != expected:
            raise RuntimeError("compositor output outcome NOT_EXERCISED")
        self.operations.append("enabled:" + ",".join(sorted(actual)))

    def panel_snapshot(self, predicate, after=0, seconds=10):
        state = self.intermediate if self.phase == "intermediate" else self.restored
        if not predicate(state):
            raise RuntimeError("consumer panel outcome NOT_EXERCISED")
        self.operations.append("panel:" + state["output"])
        return state

    def recover(self):
        return self.panel_last_output_recovery(same_editor, self.disable, self.add, "recovery")


class PanelOutputPaths(unittest.TestCase):
    def test_hyprland_fallback_then_new_output_preserves_editor(self):
        fixture = Fixture("hyprland", snapshot("FALLBACK"))
        recovered, path = fixture.recover()
        self.assertEqual(path, "hyprland-fallback-to-new-output")
        self.assertEqual(recovered["output"], "recovery")
        self.assertEqual(fixture.operations, ["disable", "enabled:FALLBACK", "panel:FALLBACK",
                                               "add", "enabled:recovery", "panel:recovery"])

    def test_non_hyprland_requires_parked_zero_surface_then_recovers(self):
        fixture = Fixture("niri", snapshot("", attached=False, focused=False))
        recovered, path = fixture.recover()
        self.assertEqual(path, "zero-surface-park-and-recover")
        self.assertTrue(same_editor(recovered))
        self.assertEqual(fixture.operations, ["disable", "panel:", "add", "panel:recovery"])

    def test_non_hyprland_fallback_does_not_count_as_zero_surfaces(self):
        fixture = Fixture("niri", snapshot("FALLBACK"))
        with self.assertRaisesRegex(RuntimeError, "NOT_EXERCISED"):
            fixture.recover()
        self.assertNotIn("add", fixture.operations)

    def test_hyprland_missing_fallback_is_not_exercised(self):
        fixture = Fixture("hyprland", snapshot("", attached=False))
        with self.assertRaisesRegex(RuntimeError, "NOT_EXERCISED"):
            fixture.recover()

    def test_writer_replacement_on_fallback_fails_before_recovery(self):
        fixture = Fixture("hyprland", snapshot("FALLBACK", preserved=False))
        with self.assertRaisesRegex(RuntimeError, "NOT_EXERCISED"):
            fixture.recover()
        self.assertNotIn("add", fixture.operations)

    def test_non_hyprland_cannot_accept_attached_empty_selection(self):
        fixture = Fixture("niri", snapshot("", attached=True))
        with self.assertRaisesRegex(RuntimeError, "NOT_EXERCISED"):
            fixture.recover()

    def test_returned_monitor_must_restore_focus_and_editor(self):
        for backend, intermediate in (("hyprland", snapshot("FALLBACK")),
                                       ("niri", snapshot("", attached=False))):
            for restored in (snapshot("recovery", preserved=False), snapshot("recovery", focused=False)):
                with self.subTest(backend=backend, restored=restored):
                    fixture = Fixture(backend, intermediate, restored)
                    with self.assertRaisesRegex(RuntimeError, "NOT_EXERCISED"):
                        fixture.recover()


class ProtocolRedaction(unittest.TestCase):
    def test_numeric_and_wall_clock_traces_are_allowlisted_before_storage(self):
        # Exercise the actual consumer rather than a duplicate filter function.
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "redacted.log"
            process = driver.ObservedProcess.__new__(driver.ObservedProcess)
            process.lines = driver.deque(maxlen=4096)
            process.log = log
            process.process = SimpleNamespace(stdout=[
                b"[12345.67] wl_keyboard#2.key(1, 2, 3, 1)\n",
                b"[16:27:22.123456] zwp_text_input_v3#7.commit_string(\"private-fixture-token\")\n",
                b"[16:27:22.123457] wl_surface#8.commit()\n",
                b"[12345.68] ext_session_lock_v1#9.locked()\n",
                b"[16:27:23.123458] -> ext_session_lock_v1#9.unlock_and_destroy()\n",
                b"qml: PANEL_SNAPSHOT {\"output\":\"recovery\"}\n",
            ])
            process.consume()
            output = log.read_text()
            self.assertNotIn("private-fixture-token", output)
            self.assertNotIn("wl_keyboard", output)
            self.assertNotIn("wl_surface", output)
            self.assertEqual(len(process.lines), 3)
            self.assertIn(".locked()", output)
            self.assertIn(".unlock_and_destroy()", output)


class HyprlandInputPlacement(unittest.TestCase):
    def test_already_focused_monitor_still_requires_pointer_reposition(self):
        # Reproduce the native early-return condition: focus is already on the
        # intended monitor, but layout restoration left the pointer elsewhere.
        session = driver.Session.__new__(driver.Session)
        target = {"name": "remediation-1", "focused": True, "x": 1280, "y": 0,
                  "width": 1280, "height": 800, "scale": 1}
        pointer = {"x": 3200, "y": 400}
        operations = []
        def hypr(*args):
            if args == ("-j", "monitors"):
                return json.dumps([target])
            if args == ("-j", "cursorpos"):
                return json.dumps(pointer)
            operations.append(args)
            if args[:2] == ("dispatch", "movecursor"):
                pointer["x"], pointer["y"] = map(int, args[2].split())
            # An already-focused monitor deliberately does not move the pointer.
            return "ok"
        session.hypr = hypr
        session.focus_hypr_input("remediation-1")
        self.assertEqual(pointer, {"x": 1920, "y": 400})
        self.assertEqual(operations, [("dispatch", "movecursor", "1920 400"),
                                      ("dispatch", "focusmonitor", "remediation-1")])

    def test_layout_restoration_is_observed_with_current_monitor_geometry(self):
        session = driver.Session.__new__(driver.Session)
        target = {"name": "remediation-1", "focused": True, "x": 0, "y": 0,
                  "width": 1280, "height": 800, "scale": 1}
        pointer = {"x": 640, "y": 400}
        def hypr(*args):
            if args == ("-j", "monitors"):
                return json.dumps([target])
            if args == ("-j", "cursorpos"):
                return json.dumps(pointer)
            if args[:2] == ("dispatch", "movecursor"):
                pointer["x"], pointer["y"] = map(int, args[2].split())
            if args[:2] == ("dispatch", "focusmonitor"):
                # Native layout restoration relocates both the monitor and its
                # correctly-focused pointer after the initial geometry query.
                target["x"] = 1280
                pointer["x"] = 1920
            return "ok"
        session.hypr = hypr
        session.focus_hypr_input("remediation-1", seconds=0.05)
        self.assertEqual(pointer, {"x": 1920, "y": 400})


class IsolatedCycleLifecycle(unittest.TestCase):
    def test_each_cycle_restarts_under_outer_session_with_unique_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            session = driver.Session.__new__(driver.Session)
            session.args = SimpleNamespace(backend="hyprland")
            session.output = Path(directory)
            session.outer_env = {"WAYLAND_DISPLAY": "outer", "XDG_RUNTIME_DIR": "/fixture"}
            session.env = {"WAYLAND_DISPLAY": "stale-nest", "HYPRLAND_INSTANCE_SIGNATURE": "stale"}
            session.compositor = None
            session.locker = None
            session.compositor_sequence = 0
            session.assert_control = lambda: None  # synthetic policy fixture, no real control
            starts = []
            ended = []
            class Process:
                def __init__(self, pid): self.pid = pid; self.returncode = None
                def poll(self): return self.returncode
                def terminate(self): self.returncode = 0; ended.append(self.pid)
            def start_hyprland():
                starts.append((dict(session.env), session.compositor_directory))
                process = Process(100 + len(starts))
                session.compositor = SimpleNamespace(process=process, finish=lambda seconds: process.returncode)
                session.env.update(WAYLAND_DISPLAY="new-nest", HYPRLAND_INSTANCE_SIGNATURE="new")
            session.start_hyprland = start_hyprland
            for _ in range(2):
                session.start()
                self.assertEqual(session.cleanup(), 0)
            self.assertEqual([env for env, _ in starts], [session.outer_env, session.outer_env])
            self.assertEqual([path.name for _, path in starts], ["001", "002"])
            self.assertEqual(ended, [101, 102])

    def test_live_locker_without_explicit_authorization_retains_compositor(self):
        session = driver.Session.__new__(driver.Session)
        session.args = SimpleNamespace(recover_owned_failures=False)
        session.locker = SimpleNamespace(process=SimpleNamespace(poll=lambda: None))
        calls = []
        session.compositor = SimpleNamespace(process=SimpleNamespace(poll=lambda: None,
                                                                     terminate=lambda: calls.append("peer closed")))
        session.blocked = lambda reason: calls.append("BLOCKED") or 125
        self.assertEqual(session.cleanup(), 125)
        self.assertEqual(calls, ["BLOCKED"])

    def test_authorized_failure_restarts_only_owned_child_without_counting_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            session = driver.Session.__new__(driver.Session)
            session.output = Path(directory)
            session.env = {}
            approval = {"uuid": "synthetic-fixture", "mode": "recover-owned-failures",
                        "user_approval_reference": "synthetic-policy-test"}
            session.owned = SimpleNamespace(authorize_recovery=lambda: approval,
                                           record={"recovery_authorization": approval})
            session.assert_control = lambda: None  # process below is the test's fake child
            session.results = [{"cycle": 1, "exit": 0}]
            signals = []
            class Process:
                pid = 201
                returncode = None
                def poll(self): return self.returncode
                def terminate(self): signals.append(self.pid); self.returncode = -15
                def wait(self, timeout): return self.returncode
            session.locker = SimpleNamespace(process=Process(), thread=SimpleNamespace(join=lambda seconds: None))
            session.compositor = SimpleNamespace(process=SimpleNamespace(pid=202))
            def no_auth(): raise RuntimeError("fixture authentication did not complete")
            session.type_and_submit = no_auth
            with patch.object(driver, "run", return_value=None):
                session.recover_owned_failure()
            record = json.loads((session.output / "failure-recovery.json").read_text())
            self.assertEqual(signals, [201])
            self.assertTrue(record["forced_restart"])
            self.assertFalse(record["normal_auth_recovery"])
            self.assertEqual(record["exit"], -15)
            self.assertEqual(session.results, [{"cycle": 1, "exit": 0}])
            self.assertIsNone(session.locker)


if __name__ == "__main__":
    unittest.main(verbosity=2)
