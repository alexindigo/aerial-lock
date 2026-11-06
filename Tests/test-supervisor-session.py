#!/usr/bin/env python3
"""Supervisor single-instance scope and engagement-confirmed duplicates.

One supervisor protects each Wayland session; several sessions share one
private user bus. A duplicate for the same session (also spelled as an absolute
socket path) never launches a locker and exits 0 only after the supervisor on
duty reports that its current locker confirmed the lock. While that supervisor
is still engaging the duplicate waits (bounded); a locker that dies loses the
confirmation until its successor reports; a report from any other process is
ignored. A supervisor that never engages or fails, and a name owner that is not
a supervisor (no reply, malformed reply), all give exit 4. A supervisor for
another session is unaffected and launches its own locker. Lockers are stub
runners; no compositor, qs or credential is used.
"""
import hashlib
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from private_runtime import PrivateRuntime

SUPERVISOR = Path(sys.argv[1]).resolve(strict=True)
UNCONFIRMED = 4


def wait_for(predicate, timeout, what):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("timed out waiting for " + what)


with tempfile.TemporaryDirectory(prefix="aerial-supervisor-") as directory, \
        PrivateRuntime("bus", "wayland-a", "wayland-b", "wayland-c", "wayland-d") as runtime:
    root = Path(directory)
    listeners = []
    for name in ("wayland-a", "wayland-b", "wayland-c", "wayland-d"):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(runtime / name))
        listener.listen(16)
        listeners.append(listener)
    marks = root / "launches"
    marks.mkdir()
    control = root / "control"
    control.mkdir()
    runner = root / "runner"
    # The stub is the supervisor's direct child, as the real runner's exec'd qs
    # is. It reports "locked" over the supervisor's channel only when told to.
    runner.write_text("#!/usr/bin/python3\n"
                      "import os, socket, sys, time\nfrom pathlib import Path\n"
                      f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
                      "from fixture_files import publish\n"
                      f"marks, control = Path({str(marks)!r}), Path({str(control)!r})\n"
                      "display = Path(os.environ['WAYLAND_DISPLAY']).name\n"
                      "ordinal = len(list(marks.glob(display + '.*'))) + 1\n"
                      "publish(marks / f'{display}.{ordinal}', str(os.getpid()))\n"
                      "report = None\n"
                      "while True:\n"
                      "    if (control / 'release').exists():\n"
                      "        raise SystemExit(0)\n"
                      "    if (control / f'die-{display}-{ordinal}').exists():\n"
                      "        raise SystemExit(70)\n"
                      "    if report is None and (control / f'engage-{display}-{ordinal}').exists():\n"
                      "        report = False\n"
                      "        path = os.environ.get('AERIAL_LOCK_ENGAGEMENT_SOCKET')\n"
                      "        if path:\n"
                      "            report = socket.socket(socket.AF_UNIX)\n"
                      "            report.connect(path)\n"
                      "            report.sendall(b'locked\\n')\n"
                      "    time.sleep(0.02)\n")
    runner.chmod(0o700)
    bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1",
                            "--address=unix:path=" + str(runtime / "bus")],
                           stdout=subprocess.PIPE, text=True)
    supervisors = []
    impostors = []
    try:
        assert select.select([bus.stdout], [], [], 10)[0], "private bus did not start"
        address = bus.stdout.readline().strip()
        assert address, "private bus did not start"
        base = {key: value for key, value in os.environ.items()
                if key not in ("HYPRLAND_INSTANCE_SIGNATURE", "AERIAL_LOCK_VIDEO_POOL",
                               "AERIAL_LOCK_RUNNER", "WAYLAND_DISPLAY", "WAYLAND_SOCKET",
                               "AERIAL_LOCK_ENGAGEMENT_SOCKET")}
        base.update(DBUS_SESSION_BUS_ADDRESS=address, XDG_RUNTIME_DIR=str(runtime),
                    AERIAL_LOCK_RUNNER=str(runner), AERIAL_LOCK_SHELL=str(root),
                    AERIAL_LOCK_PLUGIN_ROOT=str(root))

        def start(display):
            process = subprocess.Popen([str(SUPERVISOR)], env=dict(base, WAYLAND_DISPLAY=display),
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            supervisors.append(process)
            return process

        def finish(process, timeout):
            code = process.wait(timeout)
            return code, process.stdout.read()

        def launches(display):
            return sorted(path.name for path in marks.glob(display + ".*"))

        def service(display):
            canonical = os.path.realpath(runtime / display)
            return "org.aeriallock.Supervisor.s" + hashlib.sha256(canonical.encode()).hexdigest()[:32]

        def busctl(*args):
            return subprocess.run(["busctl", "--address=" + address, *args],
                                  capture_output=True, text=True, timeout=10)

        def owned(display):
            result = busctl("call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                            "NameHasOwner", "s", service(display))
            return result.stdout.strip() == "b true"

        def state(display):
            result = busctl("call", service(display), "/org/aeriallock/Supervisor",
                            "org.aeriallock.Supervisor", "State")
            return result.stdout.strip()

        def control_file(name):
            (control / name).touch()

        # 1. Same session while the first locker is still engaging: the
        #    duplicate waits, and a report from a process that is not the
        #    current locker never confirms anything.
        first = start("wayland-a")
        wait_for(lambda: launches("wayland-a"), 10, "the first session's locker")
        assert owned("wayland-a"), "the supervisor name is derived from the session socket"
        duplicate = start("wayland-a")
        time.sleep(0.5)
        assert duplicate.poll() is None, "a duplicate must not exit while the lock is unconfirmed"
        spoof = socket.socket(socket.AF_UNIX)
        spoof.connect(str(runtime / "aerial-lock" / f"supervisor-{first.pid}.sock"))
        spoof.sendall(b"locked\n")
        time.sleep(1.0)
        assert duplicate.poll() is None, "a foreign report must not release the duplicate"
        assert state("wayland-a") == 's "engaging"', "a foreign report must not confirm the lock"
        control_file("engage-wayland-a-1")
        code, output = finish(duplicate, 10)
        assert code == 0, (code, output)
        assert "another supervisor is on duty" in output, output
        assert "waiting for the supervisor on duty to confirm the lock (state: engaging)" in output, output
        assert "the supervisor on duty confirms its locker holds the session lock" in output, output
        assert "launching locker" not in output, output
        spoof.close()
        assert state("wayland-a") == 's "locked"', state("wayland-a")

        # 2. Already locked: an absolute spelling of the same socket confirms at once.
        code, output = finish(start(str(runtime / "wayland-a")), 5)
        assert code == 0 and "waiting" not in output, (code, output)
        assert launches("wayland-a") == ["wayland-a.1"], "a duplicate must not launch a second locker"

        # 3. A locker that dies loses the confirmation until its successor reports.
        control_file("die-wayland-a-1")
        wait_for(lambda: len(launches("wayland-a")) == 2, 10, "the respawned locker")
        assert state("wayland-a") == 's "engaging"', state("wayland-a")
        duplicate = start("wayland-a")
        time.sleep(1.0)
        assert duplicate.poll() is None, "a dead locker's confirmation must not survive it"
        control_file("engage-wayland-a-2")
        code, output = finish(duplicate, 10)
        assert code == 0 and "state: engaging" in output, (code, output)

        # 4. Another session is unaffected; a duplicate of a supervisor that
        #    never engages waits the whole bound, then reports "not confirmed".
        other = start("wayland-b")
        wait_for(lambda: launches("wayland-b"), 10, "the other session's locker")
        assert other.poll() is None, "a supervisor for another session must keep protecting it"
        started = time.monotonic()
        code, output = finish(start("wayland-b"), 20)
        assert code == UNCONFIRMED, (code, output)
        assert time.monotonic() - started >= 9.5, "the duplicate must wait for engagement before failing"
        assert "did not confirm the lock within" in output and "screen may be unlocked" in output, output
        assert launches("wayland-b") == ["wayland-b.1"], launches("wayland-b")

        # 5. A name owner that is not a supervisor: no reply, then an empty reply.
        tool = shutil.which("dbus-test-tool")
        assert tool, "dbus-test-tool (from dbus) is required"
        for mode, expected in (("black-hole", "gave no valid state"), ("echo", "malformed state reply")):
            impostor = subprocess.Popen([tool, mode, "--session", "--name=" + service("wayland-c")],
                                        env=base, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            impostors.append(impostor)
            wait_for(lambda: owned("wayland-c"), 10, "the impostor's name")
            code, output = finish(start("wayland-c"), 20)
            assert code == UNCONFIRMED, (mode, code, output)
            assert expected in output and "launching locker" not in output, (mode, output)
            impostor.terminate()
            impostor.wait(10)
            wait_for(lambda: not owned("wayland-c"), 10, "the impostor to leave")
        assert launches("wayland-c") == [], "an impostor's session must not get a duplicate's locker"

        # 6. A supervisor whose attempts all fail never confirms: its duplicate
        #    reports "not confirmed" while it fails, even once its name is gone.
        for ordinal in (1, 2, 3):
            control_file(f"die-wayland-d-{ordinal}")
        failing = start("wayland-d")
        wait_for(lambda: launches("wayland-d"), 10, "the failing session's locker")
        code, output = finish(start("wayland-d"), 20)
        assert code == UNCONFIRMED, (code, output)
        assert "lock engagement not confirmed" in output, output
        code, output = finish(failing, 15)
        assert code == 2 and "no attempt confirmed the lock" in output, (code, output)

        control_file("release")
        for process in (first, other):
            code, output = finish(process, 10)
            assert code == 0, output
            if process is first:
                sys.stdout.write(output)  # evidence: the on-duty supervisor's state log
                assert "ignored an engagement report from pid" in output, output
                assert output.count("the locker confirmed the session lock") == 2, output
        assert not list((runtime / "aerial-lock").glob("supervisor-*.sock")), "channels are removed on exit"
        print("SUPERVISOR_SESSION_SCOPE same_session_confirmed=3 foreign_report_ignored=1 "
              "dead_locker_unconfirmed=1 never_engaged=4 impostors=2 failing=4 other_session_launched=1")
    finally:
        (control / "release").touch()
        for process in supervisors:
            if process.poll() is None:
                process.wait(20)
        for impostor in impostors:
            if impostor.poll() is None:
                impostor.terminate()
                impostor.wait(10)
        bus.terminate()
        bus.wait(10)
        for listener in listeners:
            listener.close()
