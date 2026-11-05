#!/usr/bin/env python3
"""Private login1/systemd buses, real supervisor, controllable report peer.

No real logind method, real systemd manager or real Wayland lock is used.
"""
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from private_runtime import PrivateRuntime

binary, supervisor, peer = (Path(p).resolve(strict=True) for p in sys.argv[1:4])
source = Path(__file__).resolve().parent.parent


def wait_for(predicate, message, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("timed out: " + message)


class Case:
    def __init__(self, root, name, settings=None, display_fallback=False,
                 shell=str(source), idle_binary=binary, lock_supervisor=supervisor):
        self.root = root / name
        self.root.mkdir()
        self.binary = idle_binary
        self.processes, self.buses, self.logs = [], [], []
        self.events, self.buffer = [], b""
        self.runtime_directory = PrivateRuntime("wayland", "session", "system")
        self.runtime = self.runtime_directory.path
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.runtime / "wayland"))
        self.listener.listen(64)
        self.config = self.root / "config/aerial-lock"
        self.config.mkdir(parents=True)
        (self.config / "config.json").write_text(json.dumps({"idle": settings or {}}))
        self.launcher = self.root / "aerial-lock"
        self.runner = self.root / "runner"
        self.launcher.write_text('''#!/usr/bin/python3
import json, os
from pathlib import Path
p = Path(''' + repr(str(self.root)) + ''')
with (p / "launches").open("a") as f:
    f.write(json.dumps(dict(pid=os.getpid(), ppid=os.getppid(), sid=os.getsid(0),
                           shell=os.environ.get("AERIAL_LOCK_SHELL"),
                           managerSentinel=os.environ.get("IDLE_MANAGER_SENTINEL"))) + "\\n")
os.execve(''' + repr(str(lock_supervisor)) + ''', [''' + repr(str(lock_supervisor)) + '''],
          dict(os.environ, AERIAL_LOCK_RUNNER=''' + repr(str(self.runner)) + '''))
''')
        self.launcher.chmod(0o700)
        self.runner.write_text('''#!/usr/bin/python3
import json, os, socket, sys, time
from pathlib import Path
p = Path(''' + repr(str(self.root)) + ''')
with (p / "runners").open("a") as f: f.write(str(os.getpid()) + "\\n")
(p / "runner-args").write_text(json.dumps(sys.argv[1:]))
report = None
while not (p / "stop").exists():
    if report is None and (p / "engage").exists():
        report = socket.socket(socket.AF_UNIX)
        report.connect(os.environ["AERIAL_LOCK_ENGAGEMENT_SOCKET"])
        report.sendall(b"locked\\n")
        report.setblocking(False)
    if report:
        try: data = report.recv(1024)
        except BlockingIOError: data = None
        if data:
            with (p / "received").open("ab") as f: f.write(data)
            raise SystemExit(0)
    time.sleep(0.01)
''')
        self.runner.chmod(0o700)
        env = {k: v for k, v in os.environ.items() if k not in
               ("HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_SOCKET", "XDG_SESSION_ID", "AERIAL_LOCK_SHELL")}
        env.update(DBUS_SESSION_BUS_ADDRESS=self.bus("session"), DBUS_SYSTEM_BUS_ADDRESS=self.bus("system"),
                   QT_FORCE_STDERR_LOGGING="1", LC_ALL="C.UTF-8",
                   XDG_RUNTIME_DIR=str(self.runtime), WAYLAND_DISPLAY="wayland", XDG_CONFIG_HOME=str(self.config.parent),
                   IDLE_CASE=str(self.root), AERIAL_IDLE_LOCK_COMMAND=str(self.launcher),
                   AERIAL_LOCK_RUNNER=str(self.runner))
        if shell is not None:
            env["AERIAL_LOCK_SHELL"] = shell
        if not display_fallback:
            env["XDG_SESSION_ID"] = "test-session"
        self.env = env
        self.service = "org.aeriallock.Supervisor.s" + hashlib.sha256(str(self.runtime / "wayland").encode()).hexdigest()[:32]
        self.fake = subprocess.Popen([str(peer)], env=dict(env, IDLE_MANAGER_SENTINEL="must-not-leak"),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.log("fake.stderr"))
        self.processes.append(self.fake)
        self.await_event("ready")
        self.idle = None

    def log(self, name):
        out = (self.root / name).open("wb")
        self.logs.append(out)
        return out

    def bus(self, name):
        process = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1",
                                    "--address=unix:path=" + str(self.runtime / name)], stdout=subprocess.PIPE,
                                   stderr=self.log(name + ".stderr"))
        self.buses.append(process)
        assert select.select([process.stdout], [], [], 5)[0], "private bus ready"
        return process.stdout.readline().decode().strip()

    def pump(self):
        while select.select([self.fake.stdout], [], [], 0)[0]:
            data = os.read(self.fake.stdout.fileno(), 65536)
            if not data:
                break
            self.buffer += data
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            value = json.loads(line)
            self.events.append(value)
            print(self.root.name, value, flush=True)

    def matching(self, event):
        self.pump()
        return [e for e in self.events if e["event"] == event]

    def await_event(self, event, count=1):
        wait_for(lambda: len(self.matching(event)) >= count, event)
        return self.matching(event)[count - 1]

    def send(self, op, **values):
        count = sum(e.get("op") == op for e in self.events)
        self.fake.stdin.write((json.dumps(dict(op=op, **values)) + "\n").encode())
        self.fake.stdin.flush()
        wait_for(lambda: (self.pump() or sum(e.get("op") == op for e in self.events) > count), "ack " + op)

    def start(self, inhibitor=True, session=True):
        self.idle = subprocess.Popen([str(self.binary)], env=self.env, stdout=self.log("idle.stdout"),
                                     stderr=self.log("idle.stderr"))
        self.processes.append(self.idle)
        if inhibitor:
            self.await_event("inhibit")
        if session:
            wait_for(lambda: "logind session" in (self.root / "idle.stderr").read_text(), "session subscribed")
        wait_for(lambda: "ready" in (self.root / "idle.stderr").read_text(), "daemon ready")
        assert self.idle.poll() is None

    def launches(self):
        path = self.root / "launches"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def state(self):
        return subprocess.run(["busctl", "--address=" + self.env["DBUS_SESSION_BUS_ADDRESS"], "call", self.service,
                               "/org/aeriallock/Supervisor", "org.aeriallock.Supervisor", "State"],
                              capture_output=True, text=True, timeout=3).stdout.strip()

    def locked(self):
        (self.root / "engage").touch()
        wait_for(lambda: self.state() == 's "locked"', "real supervisor locked")

    def no_children(self):
        for task in Path(f"/proc/{self.idle.pid}/task").iterdir():
            assert not (task / "children").read_text().strip(), "aerial-idle must have no children"

    def release(self, via_idle=True):
        if via_idle:
            self.send("unlock")
        else:
            subprocess.run(["busctl", "--address=" + self.env["DBUS_SESSION_BUS_ADDRESS"], "call", self.service,
                            "/org/aeriallock/Supervisor", "org.aeriallock.Supervisor", "Release"], check=True, timeout=5)
        wait_for(lambda: (self.root / "received").exists(), "runner receives release")
        assert (self.root / "received").read_bytes() == b"release\n"
        wait_for(lambda: not self.state(), "supervisor exited")

    def close(self):
        (self.root / "stop").touch()
        for process in self.processes:
            if process is self.fake:
                continue
            if process.poll() is None:
                process.terminate()
                assert process.wait(5) == 0, (self.root / "idle.stderr").read_text()
        # Detached supervisors are not children of the test; wait for their
        # actual process state (init may briefly retain a zombie).
        for launch in self.launches():
            def stopped():
                path = Path(f'/proc/{launch["pid"]}/stat')
                return not path.exists() or path.read_text().split(") ", 1)[1].startswith("Z ")
            wait_for(stopped, "owned detached supervisor exit")
        self.send("quit")
        assert self.fake.wait(5) == 0
        for bus in self.buses:
            bus.terminate()
            bus.wait(5)
        self.listener.close()
        self.runtime_directory.cleanup()
        for log in self.logs:
            log.close()
        print(self.root.name, "DAEMON_LOG", (self.root / "idle.stderr").read_text() if self.idle else "not started", flush=True)


with tempfile.TemporaryDirectory(prefix="idle-logind-") as directory:
    root = Path(directory)
    cases = []

    def case(name, **kwargs):
        value = Case(root, name, **kwargs)
        cases.append(value)
        return value

    try:
        c = case("lock-unlock")
        c.start()
        assert c.matching("inhibit")[0]["args"] == ["sleep", "aerial-idle", "Lock the screen before sleep", "delay"]
        duplicate = subprocess.run([str(binary)], env=c.env, capture_output=True, text=True, timeout=5)
        assert duplicate.returncode == 1 and "another instance" in duplicate.stderr
        c.send("lock")
        wait_for(lambda: len(c.launches()) == 1, "one detached lock")
        c.locked()
        for _ in range(3):
            c.send("lock")
        time.sleep(0.25)
        assert len(c.launches()) == 1
        c.no_children()
        c.release()
        c.close(); cases.remove(c)
        print("T4(a,b) duplicate suppression and external release observed")

        c = case("sleep-confirm")
        c.start()
        c.send("sleep", value=True)
        wait_for(lambda: len(c.launches()) == 1, "sleep starts lock")
        wait_for(lambda: c.state() == 's "engaging"', "engaging")
        time.sleep(0.2)
        assert not c.matching("closed"), "must hold inhibitor while engaging"
        c.locked()
        closed = c.await_event("closed")
        assert closed["ms"] - c.matching("ack")[0]["ms"] < 1000
        c.send("sleep", value=False)
        c.await_event("inhibit", 2)
        c.send("sleep", value=True)
        immediate = c.await_event("closed", 2)
        sleep_event = [e for e in c.events if e.get("op") == "sleep"][-1]
        assert immediate["ms"] - sleep_event["ms"] < 500, "already locked releases promptly"
        assert len(c.launches()) == 1
        c.send("sleep", value=False)
        c.await_event("inhibit", 3)
        c.release()
        c.close(); cases.remove(c)
        print("T4(c,e,f) pipe closure follows confirmation, immediate if locked, resume reacquires")

        c = case("sleep-deadline")
        c.start()
        c.send("sleep", value=True)
        closed = c.await_event("closed")
        begin = [e for e in c.events if e.get("op") == "sleep"][0]
        elapsed = closed["ms"] - begin["ms"]
        assert 1400 <= elapsed <= 1800, elapsed
        assert c.state() == 's "engaging"'
        assert len(c.launches()) == 1
        c.close(); cases.remove(c)
        print("T4(d) unconfirmed runner guard closes at InhibitDelayMaxUSec - 500ms", elapsed)

        c = case("restart-display", display_fallback=True)
        c.start()
        assert c.matching("display") and not c.matching("session")
        c.send("drop")
        c.await_event("closed")
        c.send("claim")
        c.await_event("inhibit", 2)
        old_owner = [e["systemOwner"] for e in c.events if e.get("op") == "drop"][-1]
        new_owner = [e["systemOwner"] for e in c.events if e.get("op") == "claim"][-1]
        assert old_owner != new_owner, "restart must have a new unique bus owner"
        wait_for(lambda: (c.root / "idle.stderr").read_text().count("logind session") == 2, "resubscribed")
        c.send("lock")
        c.locked()
        assert len(c.launches()) == 1
        c.release()
        c.close(); cases.remove(c)
        print("T4(g) name owner loss/reappearance reacquires and resubscribes; User.Display fallback")

        c = case("restart-after-sleep")
        c.start()
        c.send("sleep", value=True)
        c.locked()
        c.await_event("closed")
        c.release()
        (c.root / "engage").unlink()
        (c.root / "received").unlink()
        # No old-owner resume: the replacement must establish its own cycle.
        c.send("drop")
        c.send("claim", preparing=False)
        c.await_event("inhibit", 2)
        c.send("sleep", value=True)
        wait_for(lambda: len(c.launches()) == 2, "replacement owner starts next sleep lock")
        wait_for(lambda: c.state() == 's "engaging"', "replacement lock engaging")
        time.sleep(0.2)
        assert len(c.matching("closed")) == 1, "replacement inhibitor held until its own confirmation"
        c.locked()
        c.await_event("closed", 2)
        c.release()
        c.close(); cases.remove(c)
        print("T4(g-prime) restart after sleep without old resume reacquires; next sleep holds until locked")

        c = case("restart-inflight")
        c.start()
        c.send("sleep", value=True)
        wait_for(lambda: c.state() == 's "engaging"', "old owner has an in-flight sleep cycle")
        c.send("drop")
        c.await_event("closed")
        c.send("claim", preparing=False)
        c.await_event("inhibit", 2)
        # The old guard must not close the replacement owner's awake inhibitor.
        time.sleep(1.8)
        assert len(c.matching("closed")) == 1 and c.state() == 's "engaging"'
        c.send("sleep", value=True)
        time.sleep(0.2)
        assert len(c.matching("closed")) == 1
        c.locked()
        c.await_event("closed", 2)
        assert len(c.launches()) == 1, "existing engaging lock remains first-class across restart"
        c.release()
        c.close(); cases.remove(c)
        print("T4(g-prime) old in-flight guard/poll cannot release the replacement owner's inhibitor")

        for initial in (False, True):
            c = case("preparing-initial" if initial else "preparing-replacement")
            if initial:
                c.send("preparing", value=True)
                c.start(inhibitor=False)
                old_inhibitors = 0
            else:
                c.start()
                c.send("drop")
                c.await_event("closed")
                c.send("claim", preparing=True)
                old_inhibitors = 1
            wait_for(lambda: len(c.launches()) == 1, "PreparingForSleep snapshot starts lock")
            wait_for(lambda: c.state() == 's "engaging"', "snapshot lock engaging")
            snapshot = c.await_event("preparing", 1 if initial else 2)
            assert snapshot["value"] is True
            time.sleep(0.2)
            assert len(c.matching("inhibit")) == old_inhibitors, "no inhibitor while already preparing"
            c.locked()
            time.sleep(0.15)
            assert len(c.matching("inhibit")) == old_inhibitors, "confirmation must not reacquire during sleep"
            c.send("sleep", value=False)
            c.await_event("inhibit", old_inhibitors + 1)
            c.release()
            c.close(); cases.remove(c)
        print("T4(g-prime) initial/replacement PreparingForSleep=true locks; inhibition waits for resume")

        for fault in ("error", "non-bool"):
            c = case("snapshot-" + fault)
            c.send("snapshot-fault", mode=fault)
            c.start()
            assert c.await_event("preparing")["fault"] == fault
            assert "sleep state unavailable" in (c.root / "idle.stderr").read_text()
            assert not c.launches(), "unknown snapshot takes an awake inhibitor, not a lock"
            c.send("sleep", value=True)
            wait_for(lambda: c.state() == 's "engaging"', "real signal supersedes failed snapshot")
            time.sleep(0.2)
            assert not c.matching("closed"), "fallback inhibitor holds until confirmation"
            c.locked()
            c.await_event("closed")
            c.release()
            c.close(); cases.remove(c)
        print("T4(g-prime) error/non-bool snapshot takes inhibitor; later sleep holds until locked")

        c = case("bypass")
        c.start()
        bypass = subprocess.Popen([str(c.launcher)], env=c.env, stdout=c.log("bypass.stdout"), stderr=c.log("bypass.stderr"))
        c.processes.append(bypass)
        wait_for(lambda: c.state() == 's "engaging"', "direct lock engaging")
        c.send("lock")
        c.send("sleep", value=True)
        time.sleep(0.2)
        assert len(c.launches()) == 1 and not c.matching("closed")
        c.locked()
        c.await_event("closed")
        c.release()
        assert bypass.wait(5) == 0
        c.close(); cases.remove(c)
        print("T4(h) bypass supervisor discovered engaging/locked, no second start, sleep and unlock forwarded")

        c = case("systemd")
        c.send("systemd", value=True)
        c.start()
        c.send("lock")
        unit = c.await_event("unit")
        assert unit["signature"] == "ssa(sv)a(sa(sv))" and unit["auxSignature"] == "a(sa(sv))", unit
        assert unit["name"].startswith(f"aerial-lock-{c.idle.pid}-") and unit["name"].endswith(".service")
        assert unit["mode"] == "fail"
        props = unit["properties"]
        wait_for(lambda: len(c.launches()) == 1, "transient unit starts lock")
        assert c.launches()[0]["shell"] == c.env["AERIAL_LOCK_SHELL"], c.launches()
        assert c.launches()[0]["managerSentinel"] is None, c.launches()
        assert props["ExecStart"] == [{"path": str(c.launcher), "argv": [str(c.launcher)], "ignore": False}]
        assert props["CollectMode"] == "inactive-or-failed" and props["Description"]
        expected = [f"{key}={c.env[key]}" for key in ("WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_SESSION_ID",
                     "HYPRLAND_INSTANCE_SIGNATURE", "NIRI_SOCKET", "DBUS_SESSION_BUS_ADDRESS") if key in c.env]
        expected.append("AERIAL_LOCK_SHELL=" + c.env["AERIAL_LOCK_SHELL"])
        assert props["Environment"] == expected
        c.locked()
        c.no_children()
        lock_pid = c.launches()[0]["pid"]
        assert c.launches()[0]["ppid"] != c.idle.pid
        c.idle.terminate()
        assert c.idle.wait(5) == 0
        assert Path(f"/proc/{lock_pid}").exists(), "SIGTERM must not stop the lock"
        c.release(via_idle=False)
        c.close(); cases.remove(c)
        print("T4(i) typed transient unit, expected environment and actual independent process relationship")

        # A private compiled bundle lets unset/empty cases run without /usr.
        tree = root / "compiled-source"
        shutil.copytree(source, tree, ignore=shutil.ignore_patterns(".git", "build", "__pycache__", "*.so"))
        for targets in (("clean",), ("idle/aerial-idle", "supervisor/aerial-lock-supervisor")):
            result = subprocess.run(["make", "-C", str(tree), "DATADIR=" + str(source), *targets],
                                    capture_output=True, text=True, timeout=120)
            assert result.returncode == 0, result.stdout + result.stderr
        for systemd in (False, True):
            for label, shell in (("set", str(source)), ("unset", None), ("empty", "")):
                name = ("systemd-" if systemd else "detached-") + label
                c = case(name, shell=shell, idle_binary=tree / "idle/aerial-idle",
                         lock_supervisor=tree / "supervisor/aerial-lock-supervisor")
                stale_shell = str(root / "stale-manager-shell")
                if systemd:
                    c.send("systemd", value=True, environment={"AERIAL_LOCK_SHELL": stale_shell})
                c.start()
                c.send("lock")
                c.locked()
                launch = c.launches()[0]
                expected_shell = shell if shell or not systemd else None
                assert launch["shell"] == expected_shell, (name, launch)
                assert launch["managerSentinel"] is None, (name, launch)
                assert json.loads((c.root / "runner-args").read_text())[:2] == ["--shell-dir", str(source)]
                if systemd:
                    unit = c.await_event("unit")
                    assert unit["managerEnvironment"] == ["AERIAL_LOCK_SHELL=" + stale_shell], unit
                    entries = unit["properties"]["Environment"]
                    assert [entry for entry in entries if entry.startswith("AERIAL_LOCK_SHELL=")] == (
                        ["AERIAL_LOCK_SHELL=" + shell] if shell else []), entries
                    if shell:
                        assert "UnsetEnvironment" not in unit["properties"], unit
                    else:
                        assert unit["properties"]["UnsetEnvironment"] == ["AERIAL_LOCK_SHELL"], unit
                        assert unit["unsetEnvironmentSignature"] == "as", unit
                c.release()
                c.close(); cases.remove(c)
                print("IDLE_SHELL_PROPAGATION", name, "launcher shell", repr(expected_shell), "runner shell", str(source))

        c = case("detached-survives")
        c.start()
        c.send("lock")
        c.locked()
        launch = c.launches()[0]
        c.no_children()
        assert launch["ppid"] != c.idle.pid and launch["sid"] != os.getsid(c.idle.pid), launch
        c.idle.kill()
        assert c.idle.wait(5) == -signal.SIGKILL
        c.await_event("closed")
        time.sleep(0.2)
        assert c.state() == 's "locked"' and Path(f'/proc/{launch["pid"]}').exists()
        c.release(via_idle=False)
        c.close(); cases.remove(c)
        print("T4(j) observed PPID/SID, no child, SIGKILL leaves supervisor locked and releasable", launch)

        c = case("disabled", settings={"lockOnSuspend": False, "logindLockUnlock": False})
        c.start(inhibitor=False, session=False)
        for op, values in (("lock", {}), ("unlock", {}), ("sleep", {"value": True}), ("sleep", {"value": False})):
            c.send(op, **values)
        time.sleep(0.3)
        assert not c.matching("inhibit") and not c.launches()
        assert not c.matching("session") and not c.matching("display")
        c.close(); cases.remove(c)
        print("T4(k) disabled policy takes no inhibitor and reacts to no logind event")

        c = case("no-suspend", settings={"lockOnSuspend": False})
        c.start(inhibitor=False)
        c.send("sleep", value=True)
        time.sleep(0.2)
        assert not c.matching("inhibit") and not c.launches()
        c.send("lock")
        c.locked()
        c.release()
        c.close(); cases.remove(c)

        c = case("no-lock-events", settings={"logindLockUnlock": False})
        c.start(session=False)
        c.send("lock")
        time.sleep(0.2)
        assert not c.launches()
        c.send("sleep", value=True)
        c.locked()
        c.await_event("closed")
        c.send("unlock")
        time.sleep(0.2)
        assert not (c.root / "received").exists() and c.state() == 's "locked"'
        c.release(via_idle=False)
        c.close(); cases.remove(c)
        print("T4(k) each policy switch independently disables only its own reactions")

        c = case("compositor-gone", settings={"lockOnSuspend": False, "logindLockUnlock": False})
        c.start(inhibitor=False, session=False)
        connection, _ = c.listener.accept()
        connection.close()
        assert c.idle.wait(5) == 0
        c.close(); cases.remove(c)
        print("COMPOSITOR_GONE daemon exits 0")
        print("IDLE_LOGIND all contract cases passed")
    finally:
        for c in cases:
            c.close()
