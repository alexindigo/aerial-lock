#!/usr/bin/env python3
"""Exercise rendered development-template key binds in the owned feature VM."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
from types import SimpleNamespace

from owned_instance import OwnedInstance, process_identity

spec = importlib.util.spec_from_file_location("driver", Path(__file__).with_name("remediation-driver.py"))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def wait_receipt(path, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists():
            return json.loads(path.read_text())
        time.sleep(0.02)
    raise RuntimeError("nested launch receipt NOT_EXERCISED: " + str(path))


def observe_bash(argv):
    # PATH interception observes the template's exact bash invocation. The
    # real bash -> dev runner -> common wrapper -> qs remains one child PID.
    output = Path(os.environ["AERIAL_NESTED_TEST_RESULTS"])
    owned = OwnedInstance(os.environ["AERIAL_NESTED_TEST_VM_RECORD"], os.environ["AERIAL_NESTED_TEST_ROOT"])
    owned.check(require_binaries=True)
    source = owned.paths["source"] / "aerial-lock"
    owned.check_binary(source / "native/qt-plugins/generic/libAerialLockConnectionGuard.so")
    if argv != [str(source / "Scripts/dev/run.sh")]:
        # The dev runner itself execs bash again for the common wrapper. The
        # observer must transparently preserve that same PID and output pipe.
        os.execv("/usr/bin/bash", ["bash", *argv])
    record_path = Path(os.environ["AERIAL_NESTED_TEST_SESSION_RECORD"]).resolve(strict=True)
    if not record_path.is_relative_to(owned.paths["results"]):
        raise RuntimeError("unowned nested observer session record")
    wrapper = json.loads(record_path.read_text())
    if wrapper["instance_uuid"] != owned.record["uuid"]:
        raise RuntimeError("nested observer belongs to another instance")
    owned.check_session(wrapper["session"], os.environ)
    locker = driver.ObservedProcess(["/usr/bin/bash", *argv], os.environ.copy(), output / "locker.redacted.log")
    identity = process_identity(locker.process.pid)
    # The intentional bash -> wrapper -> qs exec changes executable, not owner
    # PID/starttime. Preserve the stable identity across that transition.
    identity.pop("executable")
    (output / "launched.json").write_text(json.dumps(identity))
    try:
        locker.wait_line(lambda line: "ext_session_lock_v1" in line and ".locked()" in line)
        pid = locker.process.pid
        maps = Path(f"/proc/{pid}/maps").read_text()
        assert str(source / "native/qt-plugins/generic/libAerialLockConnectionGuard.so") in maps
        assert "libMpvQt" not in maps
        env = dict(entry.split(b"=", 1) for entry in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0") if b"=" in entry)
        assert env[b"AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID"] == str(pid).encode()
        assert b"AERIAL_LOCK_CONNECTION_GUARD_PID" not in env and b"QT_WAYLAND_RECONNECT" not in env
        assert env[b"QS_DISABLE_CRASH_HANDLER"] == b"1"
        (output / "maps.txt").write_text(maps)
        (output / "ready.json").write_text(json.dumps({"pid": pid, "argv": argv, "same_pid_exec": True}))
        status = locker.finish(60)
        assert status == 0
        assert ".unlock_and_destroy()" in (output / "locker.redacted.log").read_text()
        (output / "exit.json").write_text(json.dumps({"exit": status, "unlock_and_destroy": True}))
    except Exception as error:
        (output / "observer-failure.json").write_text(json.dumps({"error": str(error), "pid": locker.process.pid}))
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--vm-record", required=True, type=Path)
    parser.add_argument("--recover-owned-failures", action="store_true")
    parser.add_argument("--backend", required=True, choices=("niri", "hyprland"))
    parser.add_argument("--vm-key", action="store_true", help="wait for caller's emulated VM launch key")
    parser.add_argument("--ipc-control", action="store_true", help="diagnose the compositor spawn path independently of keys")
    args = parser.parse_args()
    root = args.root.resolve()
    session = driver.Session(SimpleNamespace(root=str(root), lane="debug", backend=args.backend,
        vm_record=str(args.vm_record), outputs=1, case="nested-launch-" + args.backend,
        recover_owned_failures=args.recover_owned_failures,
        hyprland_virtual_outputs=args.backend == "hyprland", pointer_helper=None))
    source = root / "src/aerial-lock"
    qs_pid = None
    passed = False
    try:
        session.config(media=False)
        bin_dir = session.output / "observe-bin"
        bin_dir.mkdir()
        shim = bin_dir / "bash"
        shim.write_text("#!/bin/sh\nexec /usr/bin/python " + shlex.quote(str(Path(__file__).resolve()))
                        + ' --observe-bash "$@"\n')
        shim.chmod(0o700)
        session.outer_env.update(PATH=str(bin_dir) + ":" + os.environ["PATH"],
            AERIAL_NESTED_TEST_RESULTS=str(session.output), WAYLAND_DEBUG="1",
            AERIAL_NESTED_TEST_ROOT=str(root), AERIAL_NESTED_TEST_VM_RECORD=str(args.vm_record.resolve()),
            AERIAL_NESTED_TEST_SESSION_RECORD=str(session.output / "compositors/001/owned-session.json"),
            AERIAL_LOCK_CONNECTION_GUARD_PID="stale-readiness", AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID="1",
            QT_WAYLAND_RECONNECT="0")
        session.start()
        session.assert_control()
        template_name = "niri.kdl" if args.backend == "niri" else "hyprland.conf"
        template = (source / "Scripts/dev/nested" / (template_name + ".in")).read_text()
        rendered = template.replace("@REPO_ROOT@", str(source)).replace("@TERMINAL@", "/usr/bin/true")
        config = session.compositor_directory / template_name
        if args.backend == "hyprland":
            # The approved virtual-output lane avoids the measured external
            # Aquamarine parent configure fault. Binding remains the template's.
            rendered += "\nmonitor = WAYLAND-1, disable\nmonitor = remediation-1,1280x800@60,0x0,1\n"
        config.write_text(rendered)
        if args.backend == "niri":
            driver.run(["niri", "validate", "-c", str(config)], session.env, capture_output=True)
            # Native niri watches its current file and applies this exact
            # template; wait for the reload before sending the native key.
            session.compositor.wait_line(lambda line: "loaded config" in line or "reloaded config" in line)
            time.sleep(1)
            # Niri's virtual-keyboard protocol forwards directly to its seat,
            # bypassing compositor hotkeys. Deliver through the outer VM's
            # focused, owned winit window instead, so the nested compositor
            # receives real wl_keyboard events and handles the template bind.
            key_env = session.outer_env.copy()
            key_env["NIRI_SOCKET"] = os.environ["NIRI_SOCKET"]
            windows = json.loads(driver.run(["niri", "msg", "-j", "windows"], key_env,
                                            capture_output=True, text=True).stdout)
            owned = [w for w in windows if w.get("pid") == session.compositor.process.pid]
            assert len(owned) == 1
            driver.run(["niri", "msg", "action", "focus-window", "--id", str(owned[0]["id"])],
                       key_env, stdout=subprocess.DEVNULL)
            if args.ipc_control:
                driver.run(["niri", "msg", "action", "spawn", "--", "bash", str(source / "Scripts/dev/run.sh")],
                           session.env, stdout=subprocess.DEVNULL)
            elif not args.vm_key:
                raise RuntimeError("winit requires the VM's physical-keycode launch leg (--vm-key)")
            # wtype allocates synthetic keycodes; winit forwards codes into its
            # own ordinary keymap, so emulated physical keys are required here.
            else:
                print("NESTED_KEY_READY " + json.dumps({"backend": "niri", "results": str(session.output)}), flush=True)
        else:
            driver.run(["hyprctl", "reload"], session.env, stdout=subprocess.DEVNULL)
            errors = driver.run(["hyprctl", "configerrors"], session.env, capture_output=True, text=True).stdout.strip()
            assert not errors, errors
            session.pointer_command("click", b"VIRTUAL_POINTER_CLICKED")
            if args.ipc_control:
                command = next(line.split(",", 3)[3].strip() for line in rendered.splitlines()
                               if line.startswith("bind = SUPER, L, exec,"))
                driver.run(["hyprctl", "dispatch", "exec", command], session.env, stdout=subprocess.DEVNULL)
            else:
                driver.run(["wtype", "-M", "logo", "-k", "l", "-m", "logo"], session.env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ready = wait_receipt(session.output / "ready.json")
        qs_pid = ready["pid"]
        session.type_and_submit()
        exited = wait_receipt(session.output / "exit.json")
        assert exited["exit"] == 0 and exited["unlock_and_destroy"]
        assert not Path(f"/proc/{qs_pid}").exists()
        session.desktop()
        result = {"backend": args.backend, "native_template_key_launch": not args.ipc_control,
                  "same_pid_guarded_dev_exec": True, "real_pam_unlock0_desktop": True,
                  "results": str(session.output)}
        (session.output / "nested-result.json").write_text(json.dumps(result, indent=2) + "\n")
        passed = True
        print(json.dumps(result, indent=2), flush=True)
    finally:
        if not qs_pid and (session.output / "launched.json").exists():
            qs_pid = json.loads((session.output / "launched.json").read_text())["pid"]
        if qs_pid and Path(f"/proc/{qs_pid}").exists():
            if not args.recover_owned_failures:
                receipt = {"status": "BLOCKED", "locker_pid": qs_pid, "driver_pid": os.getpid(),
                           "compositor_pid": session.compositor.process.pid, "results": str(session.output)}
                (root / "run/BLOCKED.json").write_text(json.dumps(receipt, indent=2))
                for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
                    signal.signal(sig, signal.SIG_IGN)
                print(json.dumps(receipt), flush=True)
                while Path(f"/proc/{qs_pid}").exists():
                    time.sleep(1)
                raise RuntimeError("failed attempt remains BLOCKED; explicit latch resolution required")
            session.owned.authorize_recovery()
            session.assert_control()
            identity = json.loads((session.output / "launched.json").read_text())
            if any(process_identity(qs_pid)[key] != value for key, value in identity.items()):
                raise RuntimeError("owned locker identity changed before authorized recovery")
            # Explicitly authorized owned-test recovery. Keep a failed outcome;
            # first try the ordinary credential path with a cleared test field.
            subprocess.run(["wtype", "-M", "ctrl", "-k", "a", "-m", "ctrl", "-k", "BackSpace"], env=session.env)
            try:
                session.type_and_submit()
                wait_receipt(session.output / "exit.json", 10)
            except Exception:
                if any(process_identity(qs_pid)[key] != value for key, value in identity.items()):
                    raise RuntimeError("owned locker identity changed before termination")
                os.kill(qs_pid, signal.SIGTERM)
                deadline = time.monotonic() + 5
                while Path(f"/proc/{qs_pid}").exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if Path(f"/proc/{qs_pid}").exists():
                    if any(process_identity(qs_pid)[key] != value for key, value in identity.items()):
                        raise RuntimeError("owned locker identity changed before termination")
                    os.kill(qs_pid, signal.SIGKILL)
        session.cleanup()
        (session.output / "result.json").write_text(json.dumps({"exit": 0 if passed else 1}) + "\n")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--observe-bash"]:
        observe_bash(sys.argv[2:])
    else:
        main()
