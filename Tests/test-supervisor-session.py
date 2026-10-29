#!/usr/bin/env python3
"""Supervisor single-instance scope: one supervisor per protected Wayland session.

Two compositor sessions share one private user bus. A duplicate supervisor for
the same session (also spelled as an absolute socket path) exits 0 without
launching; a supervisor for the other session proceeds and launches its own
locker. The locker is a stub runner; no compositor, qs or credential is used.
"""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

SUPERVISOR = Path(sys.argv[1]).resolve(strict=True)


def wait_for(predicate, timeout, what):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("timed out waiting for " + what)


with tempfile.TemporaryDirectory(prefix="aerial-supervisor-") as directory:
    root = Path(directory)
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    listeners = []
    for name in ("wayland-a", "wayland-b"):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(runtime / name))
        listener.listen(16)
        listeners.append(listener)
    marks = root / "launches"
    marks.mkdir()
    release = root / "release"
    runner = root / "runner"
    runner.write_text("#!/bin/sh\n"
                      f'touch "{marks}/$WAYLAND_DISPLAY.$$"\n'
                      f'while [ ! -e "{release}" ]; do sleep 0.05; done\n'
                      "exit 0\n")
    runner.chmod(0o700)
    bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1",
                            "--address=unix:path=" + str(root / "bus")],
                           stdout=subprocess.PIPE, text=True)
    supervisors = []
    try:
        address = bus.stdout.readline().strip()
        assert address, "private bus did not start"
        base = {key: value for key, value in os.environ.items()
                if key not in ("HYPRLAND_INSTANCE_SIGNATURE", "AERIAL_LOCK_VIDEO_POOL",
                               "AERIAL_LOCK_RUNNER", "WAYLAND_DISPLAY", "WAYLAND_SOCKET")}
        base.update(DBUS_SESSION_BUS_ADDRESS=address, XDG_RUNTIME_DIR=str(runtime),
                    AERIAL_LOCK_RUNNER=str(runner), AERIAL_LOCK_SHELL=str(root),
                    AERIAL_LOCK_PLUGIN_ROOT=str(root))

        def start(display):
            process = subprocess.Popen([str(SUPERVISOR)], env=dict(base, WAYLAND_DISPLAY=display),
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            supervisors.append(process)
            return process

        def launches(display):
            return sorted(path.name for path in marks.glob(display + ".*"))

        first = start("wayland-a")
        wait_for(lambda: launches("wayland-a"), 10, "the first session's locker")

        for spelling in ("wayland-a", str(runtime / "wayland-a")):
            duplicate = start(spelling)
            assert duplicate.wait(10) == 0, "same-session duplicate must exit 0"
            output = duplicate.stdout.read()
            assert "another supervisor is on duty" in output, output
        assert len(launches("wayland-a")) == 1, "a duplicate must not launch a second locker"

        other = start("wayland-b")
        wait_for(lambda: launches("wayland-b"), 10, "the other session's locker")
        assert other.poll() is None, "a supervisor for another session must keep protecting it"

        release.touch()
        for process in (first, other):
            assert process.wait(10) == 0, process.stdout.read()
        print("SUPERVISOR_SESSION_SCOPE same_session_duplicates=2 other_session_launched=1")
    finally:
        release.touch()
        for process in supervisors:
            if process.poll() is None:
                process.wait(10)
        bus.terminate()
        bus.wait(10)
        for listener in listeners:
            listener.close()
