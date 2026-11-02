#!/usr/bin/env python3
"""Owned-VM staged supervisor and exec-wrapper outcome checks.

A duplicate `aerial-lock` for the same session runs beside every supervised
attempt on one private bus: it must wait while the real locker is engaging and
exit 0 only once that locker confirmed the session lock, and exit 4 beside a
supervisor whose attempts never engage.
"""
from collections import deque
import argparse
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
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
    duplicate = None
    bus = None
    qs_pid = None
    reader = None
    idle = None
    inhibit = None
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
        # One private bus shared by each supervisor and its duplicate.
        with (session.output / "bus.log").open("w") as bus_log:
            bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1",
                                    "--address=unix:path=" + str(session.output / "bus")],
                                   stdout=subprocess.PIPE, stderr=bus_log, text=True, start_new_session=True)
        if not select.select([bus.stdout], [], [], 10)[0]:
            raise RuntimeError("private bus did not start")
        env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
        session.assert_control()
        def locker_log(path):
            observed = driver.ObservedProcess.__new__(driver.ObservedProcess)
            observed.lines = deque(maxlen=4096)
            observed.log = path
            # Publish the process interface before starting its FIFO reader;
            # wait_for may run before the writer opens the pipe.
            observed.process = SimpleNamespace(stdout=None,
                poll=lambda: supervisor.process.poll() if supervisor else None)
            return observed
        log = locker_log(session.output / "locker.redacted.log")
        def consume():
            with fifo.open("rb") as stream:
                log.process.stdout = stream
                log.consume()
        reader = threading.Thread(target=consume, daemon=True)
        log.thread = reader
        reader.start()
        supervisor = driver.ObservedProcess([str(stage / "bin/aerial-lock-supervisor")],
            env, session.output / "supervisor.log")
        supervisor.wait_line(lambda line: "launching locker, attempt 1/3" in line)
        duplicate = driver.ObservedProcess([str(stage / "bin/aerial-lock-supervisor")],
            env, session.output / "duplicate.log")
        # The shim execs the common runner, which execs qs. All three share the
        # supervisor's one QProcess child PID; no launcher-owned second qs fork.
        deadline = time.monotonic() + 15
        while True:
            exited = supervisor.process.poll() is not None  # sampled before the scan
            candidates = [pid for pid in descendants(supervisor.process.pid)
                          if Path(f"/proc/{pid}/comm").read_text().strip() == "qs"]
            if len(candidates) == 1 and hasattr(log, "process"):
                qs_pid = candidates[0]
                break
            if exited or time.monotonic() >= deadline: break
            time.sleep(0.01)
        if qs_pid is None: raise RuntimeError("staged supervised qs NOT_EXERCISED")
        log.wait_line(lambda line: "ext_session_lock_v1" in line and ".locked()" in line)
        # Collect the duplicate's outcome without raising while the lock is
        # held; it is asserted only after the real-PAM unlock below.
        try:
            duplicate_exit = duplicate.finish(15)
        except RuntimeError as error:
            duplicate_exit = repr(error)
        maps = Path(f"/proc/{qs_pid}/maps").read_text()
        assert "libMpvQt" not in maps and "libmpvqml.so" not in maps
        assert str(stage / "lib/aerial-lock/qt-plugins/generic/libAerialLockConnectionGuard.so") in maps
        (session.output / "supervised-no-video-maps.txt").write_text(maps)
        environment = dict(entry.split(b"=", 1) for entry in Path(f"/proc/{qs_pid}/environ").read_bytes().split(b"\0") if b"=" in entry)
        assert environment[b"AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID"] == str(qs_pid).encode()
        assert b"AERIAL_LOCK_CONNECTION_GUARD_PID" not in environment
        assert b"QT_WAYLAND_RECONNECT" not in environment
        channel = Path(env["XDG_RUNTIME_DIR"]) / "aerial-lock" / f"supervisor-{supervisor.process.pid}.sock"
        assert environment[b"AERIAL_LOCK_ENGAGEMENT_SOCKET"] == str(channel).encode()
        assert environment[b"QS_DISABLE_CRASH_HANDLER"] == b"1"
        session.type_and_submit()
        log.wait_line(lambda line: ".unlock_and_destroy()" in line, 20)
        assert supervisor.finish(20) == 0
        assert not Path(f"/proc/{qs_pid}").exists()
        supervisor.wait_line(lambda line: "child finished: exit=0 status=0" in line)
        supervisor.wait_line(lambda line: "clean exit — done" in line)
        supervisor.wait_line(lambda line: "attempt 1: the locker confirmed the session lock" in line)
        supervisor.wait_line(lambda line: "state: ended" in line)
        assert not channel.exists(), "the supervisor removes its engagement channel"
        reader.join(2)
        duplicate_log = (session.output / "duplicate.log").read_text()
        assert duplicate_exit == 0, (duplicate_exit, duplicate_log)
        assert "waiting for the supervisor on duty to confirm the lock (state: engaging)" in duplicate_log
        assert "the supervisor on duty confirms its locker holds the session lock" in duplicate_log
        assert "launching locker" not in duplicate_log
        session.desktop()
        outcomes = {"stage": str(stage), "supervised_no_video_real_pam_unlock0_desktop": True,
                    "same_pid_exec_owner": qs_pid, "stale_readiness_reconnect_removed": True,
                    "duplicate_waited_engaging_then_confirmed_exit0": True}

        # Cold-load the real installed lock for each external release route.
        # The third leg keeps the real Lock/WlSessionLock and injects only PAM
        # to observe cancellation and normal Loader teardown (T2).
        fixture_shell = session.output / "release-fixture"
        shutil.copytree(stage / "share/aerial-lock", fixture_shell)
        (fixture_shell / "Tests").mkdir()
        shutil.copyfile(root / "src/aerial-lock/Tests/lock-release-shell.qml",
                        fixture_shell / "Tests/lock-release-shell.qml")
        (fixture_shell / "shell.qml").write_text(
            'import QtQuick\nimport Quickshell\nShellRoot { settings.watchFiles: false; '
            'Loader { source: "root:/Tests/lock-release-shell.qml" } }\n')
        for name, shell_dir in (("release-dbus", stage / "share/aerial-lock"),
                                ("release-signal", stage / "share/aerial-lock"),
                                ("release-qml", fixture_shell)):
            # Each outcome owns its compositor/input state. Reusing niri's
            # virtual keyboard state across desktop probes can suppress F12
            # even without any locker (see the isolated desktop diagnostic).
            # Start a fresh owned cycle, as the remediation driver does.
            session.cleanup()
            session.start()
            env.update(WAYLAND_DISPLAY=session.env["WAYLAND_DISPLAY"], NIRI_SOCKET=session.env["NIRI_SOCKET"])
            session.assert_control()
            socket_path = os.path.realpath(Path(env["XDG_RUNTIME_DIR"]) / env["WAYLAND_DISPLAY"])
            service = "org.aeriallock.Supervisor.s" + hashlib.sha256(socket_path.encode()).hexdigest()[:32]
            release_env = dict(env, PATH=str(stage / "bin") + os.pathsep + env["PATH"],
                               AERIAL_LOCK_SHELL=str(shell_dir))
            log = locker_log(session.output / (name + "-locker.redacted.log"))
            reader = threading.Thread(target=consume, daemon=True)
            log.thread = reader
            reader.start()
            # A bare argv[0] matches the documented pkill -f expression.
            supervisor = driver.ObservedProcess(["aerial-lock-supervisor"], release_env,
                                                session.output / (name + "-supervisor.log"))
            log.wait_line(lambda line: "ext_session_lock_v1" in line and ".locked()" in line)
            supervisor.wait_line(lambda line: "state: locked" in line)
            children = [pid for pid in descendants(supervisor.process.pid)
                        if Path(f"/proc/{pid}/comm").read_text().strip() == "qs"]
            assert len(children) == 1
            qs_pid = children[0]
            if name == "release-signal":
                matches = subprocess.run(["pgrep", "-f", "^aerial-lock-supervisor"], env=release_env,
                                         capture_output=True, text=True, check=True, timeout=5)
                assert matches.stdout.split() == [str(supervisor.process.pid)], "signal only the owned instance"
                subprocess.run(["pkill", "-USR1", "-f", "^aerial-lock-supervisor"], env=release_env,
                               check=True, timeout=5)
            else:
                subprocess.run(["busctl", "--user", "call", service, "/org/aeriallock/Supervisor",
                                "org.aeriallock.Supervisor", "Release"], env=release_env, check=True, timeout=5)
            log.wait_line(lambda line: ".unlock_and_destroy()" in line, 20)
            assert supervisor.finish(20) == 0
            assert not Path(f"/proc/{qs_pid}").exists()
            supervisor.wait_line(lambda line: "state: ended" in line)
            assert sum("launching locker, attempt" in line for _, line in supervisor.lines) == 1
            reader.join(2)
            assert not reader.is_alive()
            if name == "release-qml":
                log.wait_line(lambda line: "LOCK_RELEASE_OUTCOME assertions=7 failed=false" in line)
                outcomes["qml_release_pam_aborted_tree_destroyed_unlocked_once"] = True
            session.desktop()
            outcomes[name + "_unlock0_desktop"] = True
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
            supervisor = driver.ObservedProcess([str(stage / "bin/aerial-lock-supervisor")],
                                                failure_env, session.output / (name + ".log"))
            supervisor.wait_line(lambda line: "launching locker, attempt 1/3" in line)
            duplicate = driver.ObservedProcess([str(stage / "bin/aerial-lock-supervisor")],
                                               failure_env, session.output / (name + "-duplicate.log"))
            assert supervisor.finish(15) == 3
            assert duplicate.finish(20) == 4
            duplicate_log = (session.output / (name + "-duplicate.log")).read_text()
            assert "lock engagement not confirmed" in duplicate_log and "launching locker" not in duplicate_log
            assert "confirms its locker holds the session lock" not in duplicate_log
            lines = (session.output / (name + ".log")).read_text()
            # Preserve the existing implementation's total-three-attempt bound.
            assert lines.count("launching locker, attempt") == 3
            assert lines.count(f"child finished: exit={child_exit}") == 3
            assert lines.count("respawn limit reached") == 1
            assert "staying locked" not in lines
            assert ("these attempts did not engage a lock; the current screen state is unknown" if child_exit == 72
                    else "lock engagement not confirmed; the screen may be unlocked") in lines
            if name == "failed-start": assert lines.count("child process error:") == 3
            outcomes[name + "_settled_once_three_attempts_exit3_duplicate_exit4"] = True
        # Each idle outcome has its own compositor and private buses. No idle
        # daemon or inhibitor is installed into the guest's real user session.
        for inhibited in (False, True):
            name = "idle-inhibited" if inhibited else "idle-timeout"
            session.cleanup()
            session.start()
            session.config(media=False)
            config_path = session.output / "config/aerial-lock/config.json"
            config = json.loads(config_path.read_text())
            config["idle"] = {"timeoutSeconds": 5, "respectInhibitors": True,
                              "lockOnSuspend": False, "logindLockUnlock": False}
            config_path.write_text(json.dumps(config))
            env.update(WAYLAND_DISPLAY=session.env["WAYLAND_DISPLAY"], NIRI_SOCKET=session.env["NIRI_SOCKET"])
            socket_path = os.path.realpath(Path(env["XDG_RUNTIME_DIR"]) / env["WAYLAND_DISPLAY"])
            service = "org.aeriallock.Supervisor.s" + hashlib.sha256(socket_path.encode()).hexdigest()[:32]
            idle_env = dict(env, AERIAL_IDLE_LOCK_COMMAND=str(stage / "bin/aerial-lock"),
                            PATH=str(stage / "bin") + os.pathsep + env["PATH"],
                            DBUS_SYSTEM_BUS_ADDRESS=env["DBUS_SESSION_BUS_ADDRESS"])
            log = locker_log(session.output / (name + "-locker.redacted.log"))
            reader = threading.Thread(target=consume, daemon=True)
            log.thread = reader
            reader.start()
            if inhibited:
                probe = root / "build/debug/aerial-tests/idle-inhibit-probe"
                inhibit = driver.ObservedProcess([str(probe)], idle_env, session.output / (name + "-probe.log"))
                inhibit.wait_line(lambda line: "INHIBITOR_VISIBLE frame-presented" in line)
                windows = subprocess.run(["niri", "msg", "-j", "windows"], env=idle_env,
                                         check=True, capture_output=True, text=True, timeout=5)
                assert any(w.get("app_id") == "aerial-idle-inhibit-probe" for w in json.loads(windows.stdout))
                (session.output / (name + "-windows.json")).write_text(windows.stdout)
            begin = time.monotonic()
            idle = driver.ObservedProcess([str(stage / "bin/aerial-idle")], idle_env,
                                          session.output / (name + "-daemon.log"))
            supervisor = idle  # detached supervisor logs inherit the daemon's output
            idle.wait_line(lambda line: "aerial-idle: ready" in line)

            def on_duty_pid():
                nonlocal qs_pid
                result = subprocess.run(["busctl", "--address=" + env["DBUS_SESSION_BUS_ADDRESS"], "call",
                    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "GetConnectionUnixProcessID", "s", service], env=idle_env,
                    capture_output=True, text=True, timeout=5)
                if result.returncode:
                    return None
                pid = int(result.stdout.split()[1])
                children = [child for child in descendants(pid)
                            if Path(f"/proc/{child}/comm").read_text().strip() == "qs"]
                if children:
                    qs_pid = children[0]
                return pid

            if inhibited:
                while time.monotonic() - begin < 15:
                    assert on_duty_pid() is None, "visible real idle inhibitor must prevent any lock start for 15s"
                    assert inhibit.process.poll() is None and idle.process.poll() is None
                    time.sleep(0.1)
                inhibit.process.terminate()
                assert inhibit.finish(5) == 0
                inhibit = None
                begin = time.monotonic()
            log.wait_line(lambda line: "ext_session_lock_v1" in line and ".locked()" in line, 10)
            elapsed = time.monotonic() - begin
            assert elapsed <= 10 and (inhibited or elapsed >= 5), elapsed
            idle.wait_line(lambda line: "state: locked" in line)
            pid = on_duty_pid()
            assert pid and qs_pid and Path(f"/proc/{qs_pid}").exists()
            session.type_and_submit()
            log.wait_line(lambda line: ".unlock_and_destroy()" in line, 20)
            idle.wait_line(lambda line: "state: ended" in line, 20)
            idle.wait_line(lambda line: "child finished: exit=0 status=0" in line)
            assert not Path(f"/proc/{qs_pid}").exists()
            idle.process.terminate()
            assert idle.finish(5) == 0
            idle = None
            reader.join(2)
            assert not reader.is_alive()
            session.desktop()
            outcomes[name] = {"lock_confirmed_seconds": elapsed, "real_pam_unlock_exit0_desktop": True,
                              "inhibited_seconds": 15 if inhibited else 0, "supervisor_pid": pid}
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
        for process in (inhibit, idle, duplicate, supervisor):
            if process and process.process.poll() is None:
                session.assert_control()
                process.process.terminate()
                process.finish(5)
        if bus and bus.poll() is None:
            bus.terminate()
            bus.wait(10)
        session.cleanup()
        (session.output / "result.json").write_text(json.dumps({"exit": 0 if passed else 1}, indent=2))


if __name__ == "__main__":
    main()
