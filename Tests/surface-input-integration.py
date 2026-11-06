#!/usr/bin/env python3
"""Two-output input, hotplug, fast typing and stock-Fcitx focus-out ordering.

All observations are synthetic and finish before real-PAM entry. A failed input
observation still completes the planned ordinary unlock, then reports its FAIL.
Niri winit has one output; these checks require the owned native DRM session.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import select
import shutil
import subprocess
import time
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("driver", Path(__file__).with_name("remediation-driver.py"))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class PrivateIme:
    def __init__(self, session):
        self.session = session
        self.bus = self.daemon = None

    def start(self):
        s = self.session
        config = s.output / "config/fcitx5"
        config.mkdir(parents=True)
        (config / "profile").write_text('[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n'
            '[Groups/0/Items/0]\nName=keyboard-us\n[GroupOrder]\n0=Default\n')
        self.bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1",
            "--address=unix:path=" + str(s.output / "ime-bus")], env=s.env,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        assert select.select([self.bus.stdout], [], [], 5)[0]
        s.env["DBUS_SESSION_BUS_ADDRESS"] = self.bus.stdout.readline().strip()
        s.env.update(QT_IM_MODULES="fcitx", QT_IM_MODULE="fcitx")
        self.daemon = driver.ObservedProcess(["fcitx5", "-D", "--disable", "xcb,wayland,waylandim",
            "--verbose", "*=2,key_trace=0"], s.env, s.output / "fcitx.log")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if subprocess.run(["fcitx5-remote", "--check"], env=s.env, timeout=5,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                break
            time.sleep(.05)
        else:
            raise RuntimeError("private stock Fcitx did not start")
        plugin = Path('/usr/lib/qt6/plugins/platforminputcontexts/libfcitx5platforminputcontextplugin.so')
        (s.output / "fcitx-provenance.json").write_text(json.dumps({
            "plugin": str(plugin), "sha256": hashlib.sha256(plugin.read_bytes()).hexdigest(),
            "packages": subprocess.check_output(["pacman", "-Q", "fcitx5", "fcitx5-qt", "fcitx5-mozc"], text=True),
            "integrity": subprocess.check_output(["pacman", "-Qkk", "fcitx5", "fcitx5-qt", "fcitx5-mozc"], text=True)
        }, indent=2))

    def command(self, *args):
        driver.run(["fcitx5-remote", *args], self.session.env, stdout=subprocess.DEVNULL)

    def stop(self):
        if self.daemon and self.daemon.process.poll() is None:
            self.daemon.process.terminate()
            self.daemon.finish(5)
        if self.bus and self.bus.poll() is None:
            self.bus.terminate()
            self.bus.wait(timeout=5)


def snapshot(session, predicate, after=0):
    found = None
    def match(line):
        nonlocal found
        if "SURFACE_STATE " not in line:
            return False
        state = json.loads(line.split("SURFACE_STATE ", 1)[1])
        if not predicate(state):
            return False
        found = state
        return True
    assert session.locker.wait_for(match, seconds=10, after=after, newest_first=True), "surface state not observed"
    return found


def text(session, payload, delay=0):
    argv = ["wtype"]
    if delay:
        argv.extend(["-d", str(delay)])
    driver.run([*argv, "-"], session.env, input=payload.encode(),
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--vm-record", required=True)
    parser.add_argument("--case", choices=("non-panel", "hotplug", "fast", "compose"), required=True)
    args = parser.parse_args()
    s = driver.Session(SimpleNamespace(root=args.root, lane="debug", backend="niri-drm", outputs=2,
        vm_record=args.vm_record, case="surface-input-" + args.case, recover_owned_failures=False, pointer_helper=None))
    ime = PrivateIme(s)
    result = dict(case=args.case, status="INCOMPLETE", source_identity=s.owned.record["current_source_identity"])
    try:
        s.start()
        s.config(media=False)
        s.shell = s.output / "surface-shell"
        shutil.copytree(s.stage / "share/aerial-lock", s.shell)
        shutil.copyfile(s.root / "src/aerial-lock/Tests/surface-input-theme.qml", s.shell / "Themes/SurfaceProbe.qml")
        config = s.output / "config/aerial-lock/config.json"
        settings = json.loads(config.read_text())
        settings["theme"] = "SurfaceProbe.qml"
        config.write_text(json.dumps(settings))
        names = sorted(s.drm_original_outputs)
        assert len(names) == 2, "exactly two mapped native outputs required"
        panel, other = names
        driver.run(["niri", "msg", "action", "focus-monitor", panel], s.env, stdout=subprocess.DEVNULL)
        s.start_pointer(panel)
        if args.case == "compose":
            ime.start()
        else:
            s.env.update(QT_IM_MODULES="compose", QT_IM_MODULE="compose")
        s.launch(1)
        initial = snapshot(s, lambda r: r["output"] == panel and r["focused"] and r["windowActive"])
        expected = "sinks-"
        if args.case == "compose":
            ime.command("-c")
        text(s, expected, 5)
        before = snapshot(s, lambda r: r.get("syntheticText") == expected and not r["composing"])
        if args.case == "fast":
            payload = "abcdefghijklmnopqrstuvwxyz" * 12
            writer = subprocess.Popen(["wtype", "-d", "2", "-"], env=s.env,
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            writer.stdin.write(payload.encode())
            writer.stdin.close()
            moves = 0
            while writer.poll() is None:
                target = other if moves % 2 == 0 else panel
                s.pointer_command("map " + target, b"VIRTUAL_POINTER_MAPPED")
                moves += 1
                time.sleep(.003)
            assert writer.wait(timeout=5) == 0
            expected += payload
            result["pointer_moves_during_typing"] = moves
        elif args.case == "compose":
            # Inline stock keyboard composition exercises real preedit/focus
            # without the documented unsupported CJK candidate-popup path.
            ime.command("-s", "keyboard-us")
            ime.command("-o")
            driver.run(["wtype", "-k", "dead_acute"], s.env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            before = snapshot(s, lambda r: r.get("syntheticText") == expected and r["composing"])
            s.pointer_command("map " + other, b"VIRTUAL_POINTER_MAPPED")
            expected += "\u00b4"
        elif args.case == "hotplug":
            s.drm_output(panel, "off")
            s.wait_drm_outputs({other})
            s.pointer_command("map " + other, b"VIRTUAL_POINTER_MAPPED")
            snapshot(s, lambda r: r["output"] == other and r["windowActive"])
            s.drm_output(panel, "on")
            s.wait_drm_outputs(set(names))
            s.pointer_command("map " + panel, b"VIRTUAL_POINTER_MAPPED")
            panel, other = other, panel
            text(s, "abc", 0)
            expected += "abc"
        else:
            s.pointer_command("map " + other, b"VIRTUAL_POINTER_MAPPED")
            text(s, "abc", 0)
            expected += "abc"
        # Observe the eventual state without hiding an earlier mismatch through
        # retries or additional editing. Preserve all raw synthetic snapshots.
        time.sleep(.3)
        stamp = time.monotonic_ns()
        after = snapshot(s, lambda r: r["output"] == panel, after=stamp)
        result.update(before=before, after=after, expected_synthetic=expected,
            keys_exact=after.get("syntheticText") == expected,
            composition_ended=not after["composing"] and not after["activeComposing"], panel_pinned=after["output"] == panel)
        if args.case == "fast":
            result["transfers_during_typing"] = after["generation"] - before["generation"]
            result["enough_transfers"] = result["transfers_during_typing"] >= 10
        if args.case == "compose":
            result["single_focus_out_commit"] = after["revision"] == before["revision"] + 1 and result["keys_exact"]
            ime.command("-c")
            text(s, "xyz", 0)
            continued = snapshot(s, lambda r: r.get("syntheticText", "").endswith("xyz"))
            result["after_first_new_keys"] = continued
            result["first_new_keys_exact"] = continued.get("syntheticText") == expected + "xyz"
        # The test-only stop hook belongs to the pinned panel. Visit it only
        # after the synthetic outcome is recorded, then put keyboard focus
        # back on the non-panel surface for the independent real-PAM proof.
        s.pointer_command("map " + panel, b"VIRTUAL_POINTER_MAPPED")
        driver.run(["wtype", "-k", "F10"], s.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        s.locker.wait_line(lambda line: "SURFACE_OBSERVATION_STOPPED" in line)
        s.pointer_command("map " + other, b"VIRTUAL_POINTER_MAPPED")
        result["authentication_output"] = other
        s.type_and_submit()
        s.locker.wait_line(lambda line: ".unlock_and_destroy()" in line, 20)
        result["real_pam_exit"] = s.locker.finish(20)
        assert result["real_pam_exit"] == 0
        s.desktop()
        result["desktop_input"] = True
        log = (s.output / "locker-001.redacted.log").read_text()
        assert log.count("SURFACE_THEME_CREATED") == log.count("SURFACE_THEME_DESTROYED") == 1
        assert "TypeError" not in log and "ReferenceError" not in log
        result["theme_instances"] = 1
        result["status"] = "PASS" if all(result.get(k, True) for k in
            ("keys_exact", "composition_ended", "panel_pinned", "enough_transfers", "single_focus_out_commit", "first_new_keys_exact")) else "FAIL_INPUT"
    except Exception as error:
        result.update(status="ERROR", error=repr(error))
        if s.locker:
            result["locker_exit_at_error"] = s.locker.process.poll()
        raise
    finally:
        # Preserve the original error even if the existing safety latch must
        # retain a still-held locker during cleanup.
        (s.output / "surface-input.json").write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
        s.cleanup()
        ime.stop()
        (s.output / "surface-input.json").write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n")
        print(json.dumps(dict(status=result["status"], results=str(s.output))), flush=True)
    assert result["status"] == "PASS", "lost/duplicated input or unfinished composition; retain evidence and ask"


if __name__ == "__main__":
    main()
