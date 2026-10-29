#!/usr/bin/env python3
"""Owned-VM staged supervisor and exec-wrapper outcome checks."""
from collections import deque
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import signal
import threading
import time
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("driver", Path(__file__).with_name("remediation-driver.py"))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def descendants(pid):
    result = []
    path = Path(f"/proc/{pid}/task/{pid}/children")
    if path.exists():
        for child in path.read_text().split():
            result.append(int(child))
            result.extend(descendants(int(child)))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--vm-record", required=True, type=Path)
    parser.add_argument("--stage", type=Path, help="owned staged install prefix (test-only)")
    args = parser.parse_args()
    root = args.root.resolve()
    session = driver.Session(SimpleNamespace(root=str(root), lane="debug", backend="niri", outputs=1,
        vm_record=str(args.vm_record), case="launch-integration", recover_owned_failures=False))
    if args.stage:
        stage = args.stage.resolve()
        if not stage.is_relative_to(root) or not stage.is_dir():
            raise RuntimeError("staged prefix is outside the owned feature workspace")
        session.stage = stage
    supervisor = None
    qs_pid = None
    reader = None
    passed = False
    try:
        session.start()
        session.config(media=False)
        stage = session.stage
        fifo = session.output / "locker-output.pipe"
        os.mkfifo(fifo, 0o600)
        shim = session.output / "observed-runner"
        runner = stage / "libexec/aerial-lock/aerial-lock-run"
        session.owned.check_binary(runner)
        session.owned.check_binary(stage / "bin/aerial-lock-supervisor")
        session.owned.check_binary(stage / "lib/aerial-lock/qt-plugins/generic/libAerialLockConnectionGuard.so")
        shim.write_text('#!/bin/bash\nset -euo pipefail\nexec '
                        + shlex.quote(str(runner)) + ' "$@" >'
                        + shlex.quote(str(fifo)) + ' 2>&1\n')
        shim.chmod(0o700)
        env = session.env.copy()
        for key in ("AERIAL_LOCK_VIDEO", "AERIAL_LOCK_VIDEO_POOL"):
            env.pop(key, None)
        env.update(AERIAL_LOCK_SHELL=str(stage / "share/aerial-lock"), AERIAL_LOCK_RUNNER=str(shim),
                   AERIAL_LOCK_PLUGIN_ROOT=str(stage / "lib/aerial-lock/qt-plugins"), WAYLAND_DEBUG="1",
                   AERIAL_LOCK_CONNECTION_GUARD_PID="stale-readiness",
                   AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID="1", QT_WAYLAND_RECONNECT="0")
        session.assert_control()
        log = driver.ObservedProcess.__new__(driver.ObservedProcess)
        log.lines = deque(maxlen=4096)
        log.log = session.output / "locker.redacted.log"
        def consume():
            with fifo.open("rb") as stream:
                log.process = SimpleNamespace(stdout=stream, poll=lambda: supervisor.process.poll() if supervisor else None)
                log.consume()
        reader = threading.Thread(target=consume, daemon=True)
        log.thread = reader
        reader.start()
        supervisor = driver.ObservedProcess(["dbus-run-session", "--", str(stage / "bin/aerial-lock-supervisor")],
            env, session.output / "supervisor.log")
        # The shim execs the common runner, which execs qs. All three share the
        # supervisor's one QProcess child PID; no launcher-owned second qs fork.
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            candidates = [pid for pid in descendants(supervisor.process.pid)
                          if Path(f"/proc/{pid}/comm").read_text().strip() == "qs"]
            if len(candidates) == 1 and hasattr(log, "process"):
                qs_pid = candidates[0]
                break
            if supervisor.process.poll() is not None: break
            time.sleep(0.01)
        if qs_pid is None: raise RuntimeError("staged supervised qs NOT_EXERCISED")
        log.wait_line(lambda line: "ext_session_lock_v1" in line and ".locked()" in line)
        maps = Path(f"/proc/{qs_pid}/maps").read_text()
        assert "libMpvQt" not in maps and "libmpvqml.so" not in maps
        assert str(stage / "lib/aerial-lock/qt-plugins/generic/libAerialLockConnectionGuard.so") in maps
        (session.output / "supervised-no-video-maps.txt").write_text(maps)
        environment = dict(entry.split(b"=", 1) for entry in Path(f"/proc/{qs_pid}/environ").read_bytes().split(b"\0") if b"=" in entry)
        assert environment[b"AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID"] == str(qs_pid).encode()
        assert b"AERIAL_LOCK_CONNECTION_GUARD_PID" not in environment
        assert b"QT_WAYLAND_RECONNECT" not in environment
        assert environment[b"QS_DISABLE_CRASH_HANDLER"] == b"1"
        session.type_and_submit()
        log.wait_line(lambda line: ".unlock_and_destroy()" in line, 20)
        assert supervisor.finish(20) == 0
        assert not Path(f"/proc/{qs_pid}").exists()
        supervisor.wait_line(lambda line: "child finished: exit=0 status=0" in line)
        supervisor.wait_line(lambda line: "clean exit — done" in line)
        reader.join(2)
        session.desktop()
        outcomes = {"stage": str(stage), "supervised_no_video_real_pam_unlock0_desktop": True,
                    "same_pid_exec_owner": qs_pid, "stale_readiness_reconnect_removed": True}
        plugin_root = str(stage / "lib/aerial-lock/qt-plugins")
        for name, program, plugin, fault, child_exit in (
                ("failed-start", str(session.output / "missing-runner"), plugin_root, None, 72),
                ("missing-plugin", str(runner), str(session.output / "missing-plugin"), None, 72),
                ("arming-failure", str(runner), plugin_root, "guard-thread-start", 72),
                ("monitor-failure", str(runner), plugin_root, "guard-poll-failure", 71)):
            session.assert_control()
            failure_env = env.copy()
            failure_env.update(AERIAL_LOCK_RUNNER=program, AERIAL_LOCK_PLUGIN_ROOT=plugin)
            if fault:
                failure_env.update(LD_PRELOAD=str(root / "build/debug/aerial-tests/libfull-caller-faults.so"),
                                   AERIAL_TEST_FULL_CALLER_FAULT=fault)
            supervisor = driver.ObservedProcess(["dbus-run-session", "--", str(stage / "bin/aerial-lock-supervisor")],
                                                failure_env, session.output / (name + ".log"))
            assert supervisor.finish(15) == 3
            lines = (session.output / (name + ".log")).read_text()
            # Preserve the existing implementation's total-three-attempt bound.
            assert lines.count("launching locker, attempt") == 3
            assert lines.count(f"child finished: exit={child_exit}") == 3
            assert lines.count("respawn limit reached") == 1
            assert "staying locked" not in lines
            assert ("the lock never engaged; the screen is NOT locked" if child_exit == 72
                    else "lock engagement not confirmed; the screen may be unlocked") in lines
            if name == "failed-start": assert lines.count("child process error:") == 3
            outcomes[name + "_settled_once_three_attempts_exit3"] = True
        (session.output / "launch-result.json").write_text(json.dumps(outcomes, indent=2))
        passed = True
        print(json.dumps({"results": str(session.output), "outcomes": outcomes}), flush=True)
    finally:
        if qs_pid and Path(f"/proc/{qs_pid}").exists():
            # Retain a failed secure locker and its compositor; a caller may
            # perform separately authorized normal recovery, never silent cleanup.
            receipt = {"status": "BLOCKED", "locker_pid": qs_pid, "driver_pid": os.getpid(),
                       "compositor_pid": session.compositor.process.pid, "results": str(session.output)}
            (root / "run/BLOCKED.json").write_text(json.dumps(receipt, indent=2))
            for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
                signal.signal(sig, signal.SIG_IGN)
            print(json.dumps(receipt), flush=True)
            while Path(f"/proc/{qs_pid}").exists(): time.sleep(1)
        if supervisor and supervisor.process.poll() is None:
            session.assert_control()
            supervisor.process.terminate()
            supervisor.finish(5)
        session.cleanup()
        (session.output / "result.json").write_text(json.dumps({"exit": 0 if passed else 1}, indent=2))


if __name__ == "__main__":
    main()
