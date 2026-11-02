#!/usr/bin/env python3
"""Release contract on a private bus and direct-child report socket; no real lock."""
import hashlib
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
from private_runtime import PrivateRuntime, assert_socket_paths

supervisor = Path(sys.argv[1]).resolve(strict=True)
terminal_probe = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) > 2 else None


def wait_for(predicate, what, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("timed out: " + what)


with tempfile.TemporaryDirectory(prefix="release-") as directory, PrivateRuntime("bus") as runtime:
    root = Path(directory)
    runner = root / "runner"
    runner.write_text('''#!/usr/bin/python3
import os, socket, time
from pathlib import Path
p = Path(os.environ["RELEASE_CASE"])
(p / "mask").write_text(Path("/proc/self/status").read_text())
with (p / "launches").open("a") as out: out.write(str(os.getpid()) + "\\n")
report = None
while True:
    if (p / "stop").exists(): raise SystemExit(0)
    if (p / "die").exists(): raise SystemExit(70)
    if report is None and (p / "engage").exists():
        report = socket.socket(socket.AF_UNIX)
        report.connect(os.environ["AERIAL_LOCK_ENGAGEMENT_SOCKET"])
        report.sendall(b"locked\\n")
        report.setblocking(False)
    if report:
        try: data = report.recv(1024)
        except BlockingIOError: data = None
        if data:
            with (p / "received").open("ab") as out: out.write(data)
            time.sleep(0.1)
            raise SystemExit(int(os.environ.get("RELEASE_EXIT", "0")))
    time.sleep(0.01)
''')
    runner.chmod(0o700)
    bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1",
                            "--address=unix:path=" + str(runtime / "bus")],
                           stdout=subprocess.PIPE, text=True)
    processes, listeners, cases = [], [], []
    try:
        assert select.select([bus.stdout], [], [], 10)[0]
        address = bus.stdout.readline().strip()
        env = {k: v for k, v in os.environ.items() if k not in
               ("HYPRLAND_INSTANCE_SIGNATURE", "AERIAL_LOCK_VIDEO_POOL", "WAYLAND_SOCKET")}
        env.update(DBUS_SESSION_BUS_ADDRESS=address, XDG_RUNTIME_DIR=str(runtime),
                   AERIAL_LOCK_RUNNER=str(runner), AERIAL_LOCK_SHELL=str(root))

        def call(display, method):
            name = "org.aeriallock.Supervisor.s" + hashlib.sha256(str(runtime / display).encode()).hexdigest()[:32]
            return subprocess.run(["busctl", "--address=" + address, "call", name,
                                   "/org/aeriallock/Supervisor", "org.aeriallock.Supervisor", method],
                                  capture_output=True, text=True, timeout=5)

        def state(display):
            return call(display, "State").stdout.strip()

        def start_case(name, engaging=False, code=0, probe=False):
            assert_socket_paths(runtime / name)
            case = root / name
            case.mkdir()
            cases.append(case)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(runtime / name))
            listener.listen(32)
            listeners.append(listener)
            if not engaging: (case / "engage").touch()
            case_env = dict(env, WAYLAND_DISPLAY=name, RELEASE_CASE=str(case), RELEASE_EXIT=str(code))
            process = subprocess.Popen([str(terminal_probe if probe else supervisor)], env=case_env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            processes.append(process)
            wait_for(lambda: (case / "launches").exists(), name + " runner")
            mask = int(next(line.split()[1] for line in (case / "mask").read_text().splitlines()
                            if line.startswith("SigBlk:")), 16)
            assert not mask & (1 << (signal.SIGUSR1 - 1)), "locker must not inherit blocked SIGUSR1"
            wait_for(lambda: state(name) == ('s "engaging"' if engaging else 's "locked"'), name + " state")
            return case, process, case_env

        def settled(case, process, expected=0, received=True, scheduled_before_release=False):
            code = process.wait(10)
            output = process.stdout.read()
            print(output, end="")
            assert code == expected, (code, output)
            assert len((case / "launches").read_text().splitlines()) == 1, "no respawn after release"
            if received: assert (case / "received").read_bytes() == b"release\n", "exactly one release line"
            assert output.count("respawning") == int(scheduled_before_release)
            print("RELEASE_CASE", case.name, "exit", code)
            return output

        case, process, _ = start_case("locked")
        result = call("locked", "Release")
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert call("locked", "Release").returncode == 0, "locked release is idempotent too"
        assert "release requested via D-Bus" in settled(case, process)

        for via in ("dbus", "signal"):
            name = "pending-" + via
            case, process, _ = start_case(name, engaging=True)
            if via == "dbus":
                assert call(name, "Release").returncode == 0
                assert call(name, "Release").returncode == 0, "repeated requests are idempotent"
            else:
                process.send_signal(signal.SIGUSR1)
            time.sleep(0.15)
            assert process.poll() is None and not (case / "received").exists()
            (case / "engage").touch()
            output = settled(case, process)
            assert "pending" in output and "release delivered" in output

        case, process, _ = start_case("signal")
        process.send_signal(signal.SIGUSR1)
        assert "release requested via SIGUSR1" in settled(case, process)

        case, process, _ = start_case("abnormal", code=70)
        assert call("abnormal", "Release").returncode == 0
        assert "screen state unknown" in settled(case, process, 2)

        case, process, _ = start_case("pending-dies", engaging=True)
        assert call("pending-dies", "Release").returncode == 0
        (case / "die").touch()
        settled(case, process, 2, received=False)

        case, process, _ = start_case("backoff")
        child = int((case / "launches").read_text().strip())
        (case / "die").touch()
        wait_for(lambda: not Path(f"/proc/{child}").exists(), "child reaped before backoff release")
        assert call("backoff", "Release").returncode == 0
        assert "during respawn backoff" in settled(case, process, 2, received=False,
                                                  scheduled_before_release=True)

        for confirms in (True, False):
            name = "duplicate-ok" if confirms else "duplicate-timeout"
            case, process, case_env = start_case(name, engaging=True)
            duplicate = subprocess.Popen([str(supervisor)], env=case_env, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, text=True)
            processes.append(duplicate)
            wait_for(lambda: (1 << (signal.SIGUSR1 - 1)) & int(next(
                line.split()[1] for line in Path(f"/proc/{duplicate.pid}/status").read_text().splitlines()
                if line.startswith("SigBlk:")), 16), "duplicate SIGUSR1 mask")
            duplicate.send_signal(signal.SIGUSR1)
            time.sleep(0.15)
            assert duplicate.poll() is None and process.poll() is None
            assert state(name) == 's "engaging"' and not (case / "received").exists()
            if confirms: (case / "engage").touch()
            assert duplicate.wait(15) == (0 if confirms else 4), duplicate.stdout.read()
            assert call(name, "Release").returncode == 0
            if not confirms: (case / "engage").touch()
            settled(case, process)

        if terminal_probe:
            # Pump the real Supervisor after its normal finishEpisode, without
            # entering app.exec(): observe the terminal D-Bus error before exit.
            for code, terminal in ((0, "ended"), (70, "failed")):
                name = "terminal-" + terminal
                case, process, _ = start_case(name, code=code, probe=True)
                assert call(name, "Release").returncode == 0
                wait_for(lambda: state(name) == f's "{terminal}"', name)
                result = call(name, "Release")
                assert result.returncode != 0 and "not locked" in result.stderr.lower(), result.stderr
                # busctl renders only the message: dbus-send retains the name.
                service = "org.aeriallock.Supervisor.s" + hashlib.sha256(str(runtime / name).encode()).hexdigest()[:32]
                error = subprocess.run(["dbus-send", "--bus=" + address, "--print-reply", "--dest=" + service,
                                       "/org/aeriallock/Supervisor", "org.aeriallock.Supervisor.Release"],
                                      capture_output=True, text=True, timeout=5)
                assert "org.aeriallock.Supervisor.Error.NotLocked" in error.stderr, error.stderr
                settled(case, process)
        print("SUPERVISOR_RELEASE all contract cases passed")
    finally:
        for case in cases: (case / "stop").touch()
        for process in processes:
            if process.poll() is None: process.wait(15)
        bus.terminate()
        bus.wait(10)
        for listener in listeners: listener.close()
