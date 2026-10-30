#!/usr/bin/env python3
"""Owned-feature full-caller verification; never run on the host or VM base.

All locker output is stream-filtered before persistence. Without explicit test
recovery authorization, a surviving locker retains its peer behind BLOCKED.
Authorized recovery affects only this runner's owned VM children and preserves
failed results; it is never a production failure/unlock policy.
"""
import argparse
from collections import deque
import json
import os
from pathlib import Path
import re
import resource
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

from owned_instance import OwnedInstance, session_identity


def run(argv, env, **kwargs):
    return subprocess.run(argv, env=env, check=True, timeout=15, **kwargs)


class ObservedProcess:
    def __init__(self, argv, env, log):
        self.lines = deque(maxlen=4096)
        self.process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        self.log = log
        self.thread = threading.Thread(target=self.consume, daemon=True)
        self.thread.start()

    def consume(self):
        with self.log.open("w") as stream:
            for raw in self.process.stdout:
                line = re.sub(r"\x1b\[[0-9;]*m", "", raw.decode(errors="replace"))
                # WAYLAND_DEBUG is enabled to observe actual lock/unlock messages.
                # Only this allowlist is retained, never raw keyboard/IME/data
                # traffic (including text-input surrounding/commit strings).
                if re.match(r"^\[\s*(?:\d+\.\d+|\d{2}:\d{2}:\d{2}\.\d+)\]", line):
                    if not re.search(r"ext_session_lock(?:_surface)?_v1[@#].*\.(?:locked|finished|configure|unlock_and_destroy|destroy)\(", line):
                        continue
                elif re.search(r"wl_keyboard|virtual_keyboard|text_input|input_method|data_device|primary_selection|clipboard|surrounding_text", line, re.I):
                    continue
                if self.log.name == "compositor.log" and re.search(r"\b(?:keyboard|keycode|keysym|binding|input|cursor|seat)\b", line, re.I):
                    continue
                self.lines.append((time.monotonic_ns(), line))
                stream.write(line)
                stream.flush()

    def wait_line(self, predicate, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            for stamp, line in tuple(self.lines):
                if predicate(line):
                    return stamp
            if self.process.poll() is not None:
                self.thread.join(2)
                break
            time.sleep(0.01)
        raise RuntimeError("required consumer/protocol outcome NOT_EXERCISED; see " + str(self.log))

    def finish(self, seconds=15):
        try:
            result = self.process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            raise RuntimeError("process did not exit within observation bound") from None
        self.thread.join(2)
        return result


class Session:
    def __init__(self, args):
        self.args = args
        self.owned = OwnedInstance(args.vm_record, args.root)
        self.owned.check(require_binaries=True)
        self.root = self.owned.root
        if args.recover_owned_failures:
            self.owned.authorize_recovery()
        if list((self.root / "run").glob("blocked-qs-*.json")) or (self.root / "run/BLOCKED.json").exists():
            raise RuntimeError("persistent BLOCKED latch present; inspection/permission required")
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", args.case):
            raise RuntimeError("invalid result-case name")
        prefix = args.case + "-" + args.backend + "-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-"
        self.output = Path(tempfile.mkdtemp(prefix=prefix, dir=self.owned.paths["results"]))
        self.stage = self.owned.paths["stage"] / "usr"
        self.env = os.environ.copy()
        for key in ("LD_PRELOAD", "ASAN_OPTIONS", "UBSAN_OPTIONS", "TSAN_OPTIONS",
                    "QT_QUICK_BACKEND", "QT_QPA_GENERIC_PLUGINS", "QT_WAYLAND_RECONNECT",
                    "AERIAL_LOCK_CONNECTION_GUARD_PID", "AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID",
                     "NIRI_SOCKET", "HYPRLAND_INSTANCE_SIGNATURE", "SWAYSOCK", "WAYLAND_DEBUG"):
            self.env.pop(key, None)
        self.env.update(LANG="en_US.UTF-8", LIBGL_ALWAYS_SOFTWARE="1", QSG_RHI_BACKEND="opengl",
                        QT_QPA_PLATFORM="wayland", QT_FORCE_STDERR_LOGGING="1",
                        QT_LOGGING_RULES="quickshell.service.pam.debug=true",
                        LD_LIBRARY_PATH=str(self.stage / "lib"),
                        QML_IMPORT_PATH=str(self.stage / "lib/qt6/qml"),
                        XDG_CONFIG_HOME=str(self.output / "config"),
                        XDG_CACHE_HOME=str(self.output / "cache"),
                        AERIAL_LOCK_PAM_SERVICE=self.owned.record.get("pam_fixture", {}).get("service", "aerial-lock"))
        self.owned.check_session(self.owned.record["session"], os.environ)
        self.outer_display = os.environ["WAYLAND_DISPLAY"]
        self.runtime = Path(os.environ["XDG_RUNTIME_DIR"])
        self.outer_env = self.env.copy()
        self.drm_socket = self.owned.record["session"]["ipc"]["path"]
        self.active_session_record = None
        self.session_record_path = None
        self.drm_pid = None
        self.drm_original_outputs = None
        self.compositor_sequence = 0
        self.compositor_directory = None
        self.pointer = None
        self.keyboard = None
        self.compositor = None
        self.locker = None
        self.shell = self.stage / "share/aerial-lock"
        self.results = []
        self.guard_outcomes = []

    def assert_outer(self):
        self.owned.check(require_binaries=True)
        self.owned.check_session(self.owned.record["session"], self.owned.record["environment"])

    def record_session(self, pid, backend, ipc):
        if backend == "niri-drm":
            record = self.owned.record["session"]
            if pid != record["process"]["pid"]:
                raise RuntimeError("native session identity mismatch")
        else:
            if not self.compositor or pid != self.compositor.process.pid:
                raise RuntimeError("compositor is not this driver's owned child")
            record = session_identity(pid, backend, self.runtime, self.env["WAYLAND_DISPLAY"], ipc)
        self.active_session_record = record
        self.session_record_path = self.compositor_directory / "owned-session.json"
        self.session_record_path.write_text(json.dumps({"instance_uuid": self.owned.record["uuid"],
                                                        "session": record}, indent=2))
        self.assert_control()

    def assert_control(self):
        self.owned.check(require_binaries=True)
        if self.active_session_record is None:
            raise RuntimeError("owned compositor session has not been recorded")
        self.owned.check_session(self.active_session_record, self.env)

    def start(self):
        if self.compositor and self.compositor.process.poll() is None:
            raise RuntimeError("owned compositor still running at new-cycle startup")
        # Each isolated cycle nests under the actual outer session, never under
        # the previous cycle's now-closed Wayland socket or Hyprland signature.
        self.env = self.outer_env.copy()
        self.compositor_sequence += 1
        self.compositor_directory = self.output / "compositors" / f"{self.compositor_sequence:03}"
        self.compositor_directory.mkdir(parents=True)
        if self.args.backend == "niri-drm":
            return self.start_drm()
        if self.args.backend == "hyprland":
            return self.start_hyprland()
        if self.args.backend == "sway":
            return self.start_sway()
        self.assert_outer()
        config = self.compositor_directory / "niri.kdl"
        config.write_text('hotkey-overlay { skip-at-startup; }\n'
                          'environment { QT_QPA_PLATFORM "wayland"; }\n')
        self.compositor = ObservedProcess(["niri", "-c", str(config)], self.env,
                                          self.compositor_directory / "compositor.log")
        pid = self.compositor.process.pid
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            sockets = list(self.runtime.glob(f"niri.wayland-*.{pid}.sock"))
            if len(sockets) == 1:
                display = sockets[0].name.split(".")[1]
                if display == self.outer_display:
                    raise RuntimeError("refusing outer display")
                self.env.update(WAYLAND_DISPLAY=display, NIRI_SOCKET=str(sockets[0]))
                self.record_session(pid, "niri", sockets[0])
                run(["niri", "msg", "-j", "outputs"], self.env, stdout=subprocess.DEVNULL)
                return
            if self.compositor.process.poll() is not None:
                raise RuntimeError("nested compositor exited before socket discovery")
            time.sleep(0.1)
        raise RuntimeError("nested compositor startup NOT_EXERCISED")

    def start_hyprland(self):
        self.assert_outer()
        config = self.compositor_directory / "hyprland.conf"
        virtual = getattr(self.args, "hyprland_virtual_outputs", False)
        config.write_text(("monitor = WAYLAND-1, disable\n" if virtual else "monitor = WAYLAND-1, 1280x800@60, 0x0, 1\n")
                          + "misc {\n disable_hyprland_logo = true\n disable_splash_rendering = true\n}\n")
        self.compositor = ObservedProcess(["Hyprland", "-c", str(config)], self.env,
                                          self.compositor_directory / "compositor.log")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                response = run(["hyprctl", "instances", "-j"], self.env, capture_output=True, text=True)
                instances = json.loads(response.stdout)
                owned = [instance for instance in instances if instance.get("pid") == self.compositor.process.pid]
                if len(owned) == 1 and owned[0].get("wl_socket"):
                    instance = owned[0]
                    display = instance["wl_socket"]
                    if display == self.outer_display:
                        raise RuntimeError("refusing outer display")
                    self.env.update(WAYLAND_DISPLAY=display, HYPRLAND_INSTANCE_SIGNATURE=instance["instance"])
                    self.record_session(self.compositor.process.pid, "hyprland",
                                        self.runtime / "hypr" / instance["instance"] / ".socket.sock")
                    monitors = json.loads(run(["hyprctl", "-j", "monitors"], self.env, capture_output=True, text=True).stdout)
                    if not virtual and not any(m.get("name") == "WAYLAND-1" and m.get("width", 0) > 0 for m in monitors):
                        time.sleep(0.1)
                        continue
                    for index in range(1, self.args.outputs + (1 if virtual else 0)):
                        run(["hyprctl", "output", "create", "headless", f"remediation-{index}"], self.env, stdout=subprocess.DEVNULL)
                        position = f"{(index - 1) * 1280}x0" if virtual else "auto"
                        run(["hyprctl", "keyword", "monitor", f"remediation-{index},1280x800@60,{position},1"], self.env, stdout=subprocess.DEVNULL)
                    if virtual:
                        self.start_pointer("remediation-1")
                        self.keyboard = subprocess.Popen(["wtype", "-s", "600000"], env=self.env,
                                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    return
            except (json.JSONDecodeError, subprocess.SubprocessError):
                pass
            if self.compositor.process.poll() is not None:
                raise RuntimeError("nested Hyprland exited before socket discovery")
            time.sleep(0.1)
        raise RuntimeError("nested Hyprland startup NOT_EXERCISED")

    def config(self, media=True):
        config = self.output / "config/aerial-lock"
        config.mkdir(parents=True, exist_ok=True)
        sources = []
        if media:
            file = self.owned.paths["media"] / "remediation-moving.mp4"
            if not file.exists():
                run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                     "testsrc2=size=320x240:rate=10", "-t", "5", "-c:v", "libx264",
                     "-threads", "1", "-pix_fmt", "yuv420p", str(file)], self.env)
            sources = [{"type": "file", "name": "remediation-motion", "source": str(file)}]
        (config / "config.json").write_text(json.dumps({"sources": sources,
            "theme": "Macintosh.qml", "preferredResolution": 1080}))

    def start_drm(self):
        self.assert_outer()
        receipt = self.owned.record
        if receipt["session"]["backend"] != "niri-drm":
            raise RuntimeError("native DRM session required; winit is not accepted")
        pid = receipt["session"]["process"]["pid"]
        self.env["NIRI_SOCKET"] = self.drm_socket
        self.drm_pid = pid
        self.drm_original_outputs = list(receipt["initial_outputs"])
        self.record_session(pid, "niri-drm", self.drm_socket)
        self.wait_drm_outputs(set(self.drm_original_outputs))
        (self.output / "drm-identity.json").write_text(json.dumps(receipt, indent=2))
        # Use only the dedicated fork's existing native session. No compositor
        # child is created or killed; cleanup restores its original outputs.
        self.keyboard = subprocess.Popen(["wtype", "-s", "600000"], env=self.env,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def drm_outputs(self):
        return json.loads(run(["niri", "msg", "-j", "outputs"], self.env, capture_output=True, text=True).stdout)

    def wait_drm_outputs(self, expected, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            values = self.drm_outputs()
            mapped = {name for name, output in values.items()
                      if output["current_mode"] is not None and output["logical"] is not None}
            if mapped == expected: return values
            time.sleep(0.01)
        raise RuntimeError("native DRM mapped-output outcome NOT_EXERCISED: " + repr(expected))

    def drm_output(self, name, action):
        self.assert_control()
        if not self.drm_pid or name not in self.drm_original_outputs or action not in ("off", "on"):
            raise RuntimeError("unowned DRM output operation refused")
        run(["niri", "msg", "output", name, action], self.env, stdout=subprocess.DEVNULL)

    def restore_drm_outputs(self):
        if self.drm_pid:
            for name in self.drm_original_outputs:
                self.drm_output(name, "on")
            return self.wait_drm_outputs(set(self.drm_original_outputs))

    def panel_zero_drm(self, cycle):
        names = sorted(self.drm_original_outputs)
        run(["niri", "msg", "action", "focus-monitor", names[0]], self.env, stdout=subprocess.DEVNULL)
        self.launch(cycle)
        baseline = self.panel_snapshot(lambda s: s["output"] == names[0] and s["attached"]
            and s["focused"] and s.get("windowActive") and s["hasVideo"] and s["backdropSameWindow"])
        run(["wtype", "-d", "10", "-"], self.env, input=b"synthetic-failover-draft", stdout=subprocess.DEVNULL)
        run(["wtype", "-M", "shift", "-k", "Left", "-k", "Left", "-k", "Left", "-m", "shift"],
            self.env, stdout=subprocess.DEVNULL)
        saved = self.panel_snapshot(lambda s: s["syntheticDraft"] and s.get("cursor") == 21 and s.get("anchor") == 24)
        keys = ("cursor", "anchor", "revision", "writer", "generation", "policy", "scope", "latched", "initialWindowOpen")
        def preserved(state):
            return state["syntheticDraft"] and all(state.get(key) == saved[key] for key in keys)
        other = next(name for name in names if name != baseline["output"])
        stamp = time.monotonic_ns()
        self.drm_output(other, "off")
        self.wait_drm_outputs({baseline["output"]})
        self.panel_snapshot(lambda s: s["output"] == baseline["output"] and preserved(s), after=stamp)
        self.drm_output(other, "on")
        self.wait_drm_outputs(set(names))
        stamp = time.monotonic_ns()
        self.drm_output(baseline["output"], "off")
        self.wait_drm_outputs({other})
        self.panel_snapshot(lambda s: s["output"] == other and s["focused"] and s.get("windowActive")
                            and s["hasVideo"] and s["backdropSameWindow"] and preserved(s), after=stamp)
        stamp = time.monotonic_ns()
        self.drm_output(other, "off")
        empty = self.wait_drm_outputs(set())
        parked = self.panel_snapshot(lambda s: s["output"] == "" and not s["attached"] and preserved(s), after=stamp)
        if self.locker.process.poll() is not None:
            raise RuntimeError("locker transport/process did not survive genuine zero outputs")
        stamp = time.monotonic_ns()
        self.drm_output(baseline["output"], "on")
        readded = self.wait_drm_outputs({baseline["output"]})
        recovered = self.panel_snapshot(lambda s: s["output"] == baseline["output"] and s["attached"]
            and s["focused"] and s.get("windowActive") and s["hasVideo"] and s["backdropSameWindow"] and preserved(s), after=stamp)
        (self.output / f"zero-output-{cycle:03}.json").write_text(json.dumps({"native_empty": empty,
            "parked": parked, "native_readded": readded, "recovered": recovered}, indent=2))
        run(["wtype", "-M", "ctrl", "-k", "a", "-m", "ctrl", "-k", "BackSpace"], self.env, stdout=subprocess.DEVNULL)
        self.unlock(cycle)
        self.results[-1].update(panel_preservation={key: saved[key] for key in keys},
            last_output_recovery="zero-surface-park-and-recover", output_recovered=recovered["output"],
            native_zero_mapped_outputs=True, compositor_pid=self.drm_pid, backend="niri-drm")
        log = (self.output / f"locker-{cycle:03}.redacted.log").read_text()
        if log.count("REMEDIATION_THEME_CREATED") != 1 or log.count("REMEDIATION_THEME_DESTROYED") != 1:
            raise RuntimeError("theme/editor recreated during native DRM output recovery")
        (self.output / "cycles.json").write_text(json.dumps(self.results, indent=2))
        self.restore_drm_outputs()

    def start_sway(self):
        self.assert_outer()
        config = self.compositor_directory / "sway.conf"
        config.write_text("xwayland disable\noutput * mode 1280x800 scale 1\nseat seat0 fallback true\n")
        env = self.env.copy()
        env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS=str(self.args.outputs),
                   WLR_RENDERER="gles2", WLR_RENDERER_ALLOW_SOFTWARE="1")
        self.compositor = ObservedProcess(["sway", "--verbose", "--config", str(config)], env,
                                          self.compositor_directory / "compositor.log")
        socket = self.runtime / f"sway-ipc.{os.getuid()}.{self.compositor.process.pid}.sock"
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            display = next((re.search(r"Running compositor on wayland display '([^']+)'", line)[1]
                for _, line in tuple(self.compositor.lines) if "Running compositor on wayland display '" in line), None)
            if display and socket.exists():
                if display == self.outer_display: raise RuntimeError("refusing outer display")
                self.env.update(WAYLAND_DISPLAY=display, SWAYSOCK=str(socket))
                self.record_session(self.compositor.process.pid, "sway", socket)
                outputs = json.loads(run(["swaymsg", "-t", "get_outputs", "-r"], self.env,
                                         capture_output=True, text=True).stdout)
                active = [o for o in outputs if o["active"]]
                if len(active) == self.args.outputs:
                    self.keyboard = subprocess.Popen(["wtype", "-s", "600000"], env=self.env,
                                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    return
            if self.compositor.process.poll() is not None:
                raise RuntimeError("owned Sway exited before headless output discovery")
            time.sleep(0.05)
        raise RuntimeError("owned Sway startup NOT_EXERCISED")

    def sway(self, command):
        self.assert_control()
        responses = json.loads(run(["swaymsg", "-r", command], self.env, capture_output=True, text=True).stdout)
        if not responses or any(not response.get("success") for response in responses):
            raise RuntimeError("Sway output operation failed: " + json.dumps(responses))

    def sway_outputs(self):
        return json.loads(run(["swaymsg", "-r", "-t", "get_outputs"], self.env,
                              capture_output=True, text=True).stdout)

    def panel_zero_outputs(self, cycle):
        self.launch(cycle)
        baseline = self.panel_snapshot(lambda s: s["attached"] and s["focused"] and s["hasVideo"] and s["backdropSameWindow"])
        self.start_pointer(baseline["output"])
        self.pointer_command("click", b"VIRTUAL_POINTER_CLICKED")
        run(["wtype", "-d", "10", "-"], self.env, input=b"synthetic-failover-draft", stdout=subprocess.DEVNULL)
        run(["wtype", "-M", "shift", "-k", "Left", "-k", "Left", "-k", "Left", "-m", "shift"],
            self.env, stdout=subprocess.DEVNULL)
        saved = self.panel_snapshot(lambda s: s["syntheticDraft"] and s.get("cursor") == 21 and s.get("anchor") == 24)
        keys = ("cursor", "anchor", "revision", "writer", "generation", "policy", "scope", "latched", "initialWindowOpen")
        def preserved(snapshot):
            return snapshot["syntheticDraft"] and all(snapshot.get(k) == saved[k] for k in keys)
        active = [o for o in self.sway_outputs() if o["active"]]
        if len(active) > 1:
            other = next(o["name"] for o in active if o["name"] != baseline["output"])
            stamp = time.monotonic_ns()
            self.sway(f"output {other} disable")
            self.panel_snapshot(lambda s: s["output"] == baseline["output"] and preserved(s), after=stamp)
            self.sway(f"output {other} enable")
            stamp = time.monotonic_ns()
            self.pointer_command("unmap", b"VIRTUAL_POINTER_UNMAPPED")
            self.sway(f"output {baseline['output']} disable")
            survivor = self.panel_snapshot(lambda s: s["output"] not in ("", baseline["output"]) and s["attached"] and preserved(s), after=stamp)
            self.pointer_command("map " + survivor["output"], b"VIRTUAL_POINTER_MAPPED")
            self.panel_snapshot(lambda s: s["output"] == survivor["output"] and s["focused"] and s["hasVideo"]
                                and s["backdropSameWindow"] and preserved(s), after=stamp)
        names = [o["name"] for o in self.sway_outputs() if o["active"]]
        parked = {}
        def disable():
            for name in names: self.sway(f"output {name} disable")
            parked["native_active_outputs"] = [o["name"] for o in self.sway_outputs() if o["active"]]
            if parked["native_active_outputs"]: raise RuntimeError("genuine zero active outputs NOT_EXERCISED")
        recovered_name = "HEADLESS-" + str(1 + max(int(o["name"].split("-")[-1]) for o in self.sway_outputs()
                                                 if o["name"].startswith("HEADLESS-")))
        def add():
            self.sway("create_output")
        recovered, path = self.panel_recover_zero_outputs(preserved, disable, add, recovered_name)
        self.pointer_command("map " + recovered["output"], b"VIRTUAL_POINTER_MAPPED")
        self.pointer_command("click", b"VIRTUAL_POINTER_CLICKED")
        run(["wtype", "-M", "ctrl", "-k", "a", "-m", "ctrl", "-k", "BackSpace"], self.env, stdout=subprocess.DEVNULL)
        self.unlock(cycle)
        self.results[-1].update(panel_preservation={k: saved[k] for k in keys},
                                last_output_recovery=path, native_zero_outputs=parked,
                                initial_active_outputs=len(active),
                                nonselected_selected_sway_paths=len(active) > 1,
                                recovered_output=recovered["output"])
        log = (self.output / f"locker-{cycle:03}.redacted.log").read_text()
        if log.count("REMEDIATION_THEME_CREATED") != 1 or log.count("REMEDIATION_THEME_DESTROYED") != 1:
            raise RuntimeError("theme/editor recreated during zero-output recovery")
        (self.output / "cycles.json").write_text(json.dumps(self.results, indent=2))

    def launch(self, cycle, fault=None):
        self.assert_control()
        self.owned.check_binary(self.stage / "libexec/aerial-lock/aerial-lock-run")
        self.owned.check_binary(self.stage / "lib/aerial-lock/qt-plugins/generic/libAerialLockConnectionGuard.so")
        env = self.env.copy()
        env["WAYLAND_DEBUG"] = "1"
        if fault:
            env["LD_PRELOAD"] = str(self.root / "build/debug/aerial-tests/libfull-caller-faults.so")
            env["AERIAL_TEST_FULL_CALLER_FAULT"] = fault
        self.locker = ObservedProcess([str(self.stage / "libexec/aerial-lock/aerial-lock-run"),
            "--shell-dir", str(self.shell),
            "--plugin-root", str(self.stage / "lib/aerial-lock/qt-plugins")], env,
            self.output / f"locker-{cycle:03}.redacted.log")
        secure = self.locker.wait_line(lambda line: "ext_session_lock_v1" in line and ".locked()" in line)
        maps = Path(f"/proc/{self.locker.process.pid}/maps").read_text()
        if "libMpvQt" in maps or str(self.stage / "lib/aerial-lock/qt-plugins/generic/libAerialLockConnectionGuard.so") not in maps:
            raise RuntimeError("loaded guard/backend provenance mismatch")
        (self.output / f"maps-{cycle:03}.txt").write_text(maps)
        return secure

    def type_and_submit(self, wrong=False):
        self.assert_control()
        fixture = self.owned.auth_fixture()
        env = self.env.copy()
        env.pop("WAYLAND_DEBUG", None)
        if wrong:
            payload = b"deliberately-invalid-fixture-response"
        else:
            path = Path(fixture["secret_file"])
            metadata = path.stat()
            if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
                raise RuntimeError("credential fixture ownership/mode mismatch")
            # Remove only the fixture-file line delimiter, not password whitespace.
            payload = path.read_bytes().removesuffix(b"\n")
            if not payload or b"\n" in payload or b"\r" in payload:
                raise RuntimeError("unexpected credential fixture format")
        run(["wtype", "-d", "10", "-"], env, input=payload,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        payload = None
        submitted = time.monotonic_ns()
        run(["wtype", "-k", "Return"], env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return submitted

    def desktop(self):
        self.assert_control()
        self.owned.check_binary(self.root / "build/debug/aerial-tests/desktop-input-probe")
        probe = ObservedProcess([str(self.root / "build/debug/aerial-tests/desktop-input-probe")],
                                 self.env, self.output / "desktop-probe.log")
        probe.wait_line(lambda line: "DESKTOP_INPUT_READY" in line, 5)
        run(["wtype", "-k", "F12"], self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        probe.wait_line(lambda line: "DESKTOP_INPUT_RECEIVED" in line, 5)
        if probe.finish(5) != 0:
            raise RuntimeError("desktop native input outcome failed")

    def prompt_fixture(self):
        self.assert_control()
        self.owned.check_binary(self.stage / "libexec/aerial-lock/aerial-lock-run")
        shell = self.output / "prompt-shell"
        shutil.copytree(self.stage / "share/aerial-lock", shell)
        (shell / "Tests").mkdir()
        shutil.copyfile(self.root / "src/aerial-lock/Tests/lock-lifecycle-shell.qml",
                        shell / "Tests/lock-lifecycle-shell.qml")
        # Keep the fixture at root:/Tests so its relative imports canonicalize
        # to exactly the same root:/Services types as bundled runtime themes.
        (shell / "shell.qml").write_text('import QtQuick\nimport Quickshell\n'
            'ShellRoot { settings.watchFiles: false; '
            'Loader { source: "root:/Tests/lock-lifecycle-shell.qml"; } }\n')
        # A short inactivity watchdog lets the fixture outlast it while PAM
        # waits for the user, and observe it firing on a silent PAM call.
        config = self.output / "config/aerial-lock"
        config.mkdir(parents=True, exist_ok=True)
        (config / "config.json").write_text(json.dumps({"sources": [], "pamWatchdogTimeoutMs": 800}))
        fixture = ObservedProcess([str(self.stage / "libexec/aerial-lock/aerial-lock-run"),
            "--shell-dir", str(shell), "--plugin-root", str(self.stage / "lib/aerial-lock/qt-plugins")],
            self.env, self.output / "prompt-state.log")
        self.locker = fixture
        fixture.wait_line(lambda line: "LOCK_LIFECYCLE_OUTCOME assertions=43 failed=false" in line)
        if fixture.finish() != 0:
            raise RuntimeError("actual controller prompt fixture failed")
        self.locker = None

    def prepare_panel(self):
        self.shell = self.output / "panel-shell"
        shutil.copytree(self.stage / "share/aerial-lock", self.shell)
        shutil.copyfile(self.root / "src/aerial-lock/Tests/remediation-theme.qml",
                        self.shell / "Themes/RemediationProbe.qml")
        path = self.output / "config/aerial-lock/config.json"
        config = json.loads(path.read_text())
        config["theme"] = "RemediationProbe.qml"
        path.write_text(json.dumps(config))

    def prepare_resource(self, resolution=240, playback_only=False):
        sizes = {240: (320, 240), 1080: (1920, 1080), 2160: (3840, 2160)}
        width, height = sizes[resolution]
        clips = []
        for index, hue in enumerate((0, 110)):
            file = self.owned.paths["media"] / f"resource-{resolution}-{index}.mp4"
            if not file.exists():
                subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                     f"testsrc2=size={width}x{height}:rate=10", "-vf", f"hue=h={hue}",
                     "-t", "5", "-c:v", "libx264", "-preset", "ultrafast", "-threads", "1",
                      "-pix_fmt", "yuv420p", str(file)], env=self.env, check=True, timeout=120)
            details = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=width,height", "-of", "json", str(file)], self.env,
                capture_output=True, text=True).stdout)["streams"]
            if details != [{"width": width, "height": height}]:
                raise RuntimeError("resource clip resolution mismatch")
            clips.append({"type": "file", "name": f"resource-{index}", "source": str(file)})
        label = "playback" if playback_only else "sampler"
        self.resource_label = f"{resolution}-{label}"
        self.resource_directory = self.output / self.resource_label
        self.resource_directory.mkdir()
        self.shell = self.output / f"resource-shell-{self.resource_label}"
        shutil.copytree(self.stage / "share/aerial-lock", self.shell)
        shutil.copyfile(self.root / "src/aerial-lock/Tests/resource-theme.qml",
                        self.shell / "Themes/ResourceProbe.qml")
        if playback_only:
            # A disposable control copy, not a product feature/runtime switch.
            # Keep the exact production playback/render/auth path; replace only
            # the sampler with its inert color/shutdown contract in this copy.
            background = self.shell / "Modules/Lock/LockBackground.qml"
            original = background.read_text()
            sampler = ('    AccentSampler {\n        id: sampler\n        player: player\n'
                       '        trackKey: root.currentFilename\n'
                       '        shotDirectory: root.frameDirectory\n'
                       '        active: root.samplingActive\n'
                       '        onSamplingFailed: function (reason) { root.loadFailed(reason) }\n    }')
            if original.count(sampler) != 1:
                raise RuntimeError("playback-only fixture no longer matches production sampler boundary")
            background.write_text(original.replace(sampler, '    QtObject {\n        id: sampler\n'
                '        readonly property color accent: "transparent"\n        function shutdown() {}\n    }'))
        config = self.output / "config/aerial-lock/config.json"
        config.write_text(json.dumps({"sources": clips, "theme": "ResourceProbe.qml", "preferredResolution": 1080}))

    def resource_media(self, after=0):
        for stamp, line in reversed(tuple(self.locker.lines)):
            if stamp >= after and "RESOURCE_MEDIA " in line:
                return json.loads(line.split("RESOURCE_MEDIA ", 1)[1])
        return None

    def connection_loss(self):
        self.assert_control()
        self.owned.check_binary(self.root / "build/debug/aerial-tests/connection-loss-probe")
        fixtures = {}
        for name in ("connection-loss-fixture", "connection-loss-video-fixture"):
            directory = self.output / name
            directory.mkdir()
            shutil.copyfile(self.root / f"src/aerial-lock/Tests/{name}.qml", directory / "shell.qml")
            fixtures[name] = directory
        self.env["AERIAL_LOCK_TEST_VIDEO"] = str(self.owned.paths["media"] / "remediation-moving.mp4")
        outcomes = self.guard_outcomes
        cases = [("gui", False, None, "CONNECTION_LOSS_READY"),
                 ("blocked-gui", True, None, "CONNECTION_LOSS_READY"),
                 ("video", False, None, "CONNECTION_LOSS_VIDEO_READY"),
                 ("video-blocked-gui", True, None, "CONNECTION_LOSS_VIDEO_READY"),
                 ("retirement", False, "guard-retirement", "CONNECTION_LOSS_RETIREMENT_GUI_HELD"),
                 ("exit-trap", True, "guard-exit-trap", "CONNECTION_LOSS_READY"),
                 ("eintr", True, "guard-eintr", "CONNECTION_LOSS_READY"),
                 ("logger", False, "guard-logger", "CONNECTION_LOSS_LOGGER_HELD"),
                 ("native-lifecycle", False, None, "CONNECTION_LOSS_READY")]
        for cycle in range(1, self.args.cycles + 1):
            for name, blocked, fault, marker in cases:
                shell = fixtures["connection-loss-video-fixture" if name.startswith("video") or name == "retirement"
                                 else "connection-loss-fixture"]
                argv = [str(self.root / "build/debug/aerial-tests/connection-loss-probe"),
                        "--root", str(self.root), "--shell-dir", str(shell),
                        "--vm-record", str(self.owned.path), "--session-record", str(self.session_record_path),
                        "--ready-marker", marker, "--intact-ms", "250"]
                if blocked: argv.append("--blocked-gui")
                if fault: argv.extend(["--fault", fault])
                if name == "native-lifecycle":
                    argv.extend(["--native-lifecycle", "--intact-ms", "1500"])
                probe = ObservedProcess(argv, self.env, self.output / f"guard-{cycle:03}-{name}.log")
                self.locker = probe  # retain the probe/peer if its observation fails
                if probe.finish(30) != 0:
                    raise RuntimeError("native guard case failed: " + name)
                line = next((line for _, line in tuple(probe.lines) if "CONNECTION_LOSS_OUTCOME " in line), None)
                if line is None: raise RuntimeError("native guard exit outcome NOT_EXERCISED")
                elapsed = int(re.search(r"\bns=(\d+)", line)[1])
                exit_code = int(re.search(r"\bexit=(\d+)", line)[1])
                guard_proof = blocked or name in ("retirement", "logger", "native-lifecycle")
                assert elapsed <= 250000000 and (exit_code == 70 if guard_proof else exit_code in (70, 255))
                outcomes.append({"cycle": cycle, "case": name, "locker_exit": exit_code,
                                 "independent_guard_proof": guard_proof, "loss_to_exit_ns": elapsed})
                (self.output / "guard-outcomes.json").write_text(json.dumps(outcomes, indent=2))
                self.locker = None
        for fault in ("guard-thread-start", "guard-poll-failure"):
            probe = ObservedProcess([str(self.root / "build/debug/aerial-tests/connection-loss-probe"),
                "--root", str(self.root), "--shell-dir", str(fixtures["connection-loss-fixture"]),
                "--vm-record", str(self.owned.path), "--session-record", str(self.session_record_path),
                "--fault", fault], self.env, self.output / f"{fault}.log")
            self.locker = probe
            if probe.finish(30) != 0: raise RuntimeError("guard failure did not fail closed: " + fault)
            probe.wait_line(lambda line: "GUARD_FAILURE_OUTCOME " in line and "exit=71 " in line)
            self.locker = None
        summary = {"cycles": self.args.cycles, "loss_cases": len(outcomes),
                   "independent_guard_cases": sum(o["independent_guard_proof"] for o in outcomes),
                   "max_loss_to_exit_ms": max(o["loss_to_exit_ns"] for o in outcomes) / 1e6,
                   "arming_monitor_failure_exit71": 2}
        (self.output / "guard-result.json").write_text(json.dumps(summary, indent=2))
        return summary

    def output_count(self):
        if self.args.backend.startswith("niri"):
            return len(json.loads(run(["niri", "msg", "-j", "outputs"], self.env,
                                      capture_output=True, text=True).stdout))
        if self.args.backend == "hyprland":
            return len(json.loads(self.hypr("-j", "monitors")))
        outputs = json.loads(run(["swaymsg", "-t", "get_outputs", "-r"], self.env,
                                 capture_output=True, text=True).stdout)
        return len([o for o in outputs if o["active"]])

    @staticmethod
    def global_tmp_inventory():
        # Frame grabs must never reach the shared temporary directory.
        return sorted(name for name in os.listdir("/tmp") if not name.startswith("systemd-private-"))

    def resource_run(self, duration, sample_seconds, transitions=None, playback_only=False):
        cycle = len(self.results) + 1
        tmp_before = self.global_tmp_inventory()
        self.launch(cycle)
        self.locker.wait_line(lambda line: "RESOURCE_MEDIA " in line and '"hasVideo":true' in line, 20)
        outputs = self.output_count()
        frames = self.runtime / "aerial-lock" / f"locker-{self.locker.process.pid}"
        started = time.monotonic()
        samples = []
        media = None
        while True:
            if self.locker.process.poll() is not None:
                raise RuntimeError("resource locker exited before required duration/outcome")
            proc = Path(f"/proc/{self.locker.process.pid}")
            status = {line.split(":", 1)[0]: line.split(":", 1)[1].strip()
                      for line in (proc / "status").read_text().splitlines() if ":" in line}
            memory = {line.split(":", 1)[0]: int(line.split()[1]) for line in Path("/proc/meminfo").read_text().splitlines()}
            limits = (proc / "limits").read_text().splitlines()
            fd_limit = int(next(line.split()[3] for line in limits if line.startswith("Max open files")))
            rollup = (proc / "smaps_rollup").read_text().splitlines()
            pss = int(next(line.split()[1] for line in rollup if line.startswith("Pss:"))) * 1024
            media = self.resource_media() or media
            rss = int(status["VmRSS"].split()[0]) * 1024
            fds = len(list((proc / "fd").iterdir()))
            frame_files = len(list(frames.iterdir())) if frames.is_dir() else 0
            sample = {"elapsed_seconds": time.monotonic() - started, "rss_bytes": rss, "pss_bytes": pss,
                      "fds": fds, "fd_limit": fd_limit, "mem_available_kb": memory["MemAvailable"],
                      "mem_total_kb": memory["MemTotal"], "media": media, "frame_files": frame_files}
            samples.append(sample)
            with (self.resource_directory / "resource-samples.jsonl").open("a") as stream:
                stream.write(json.dumps(sample) + "\n")
            if rss > 1024**3 or fds >= fd_limit * 0.75 or memory["MemAvailable"] < memory["MemTotal"] * 0.25:
                raise RuntimeError("original resource budget exceeded; see resource-samples.jsonl")
            if frame_files > outputs or (playback_only and frame_files):
                raise RuntimeError("frame-grab files exceed the output bound; see resource-samples.jsonl")
            elapsed = time.monotonic() - started
            if transitions is not None and media and media["transitions"] >= transitions + 1 \
                    and (playback_only or (media["sensed"] >= transitions + 1 and media["accentReady"])):
                break
            if transitions is None and elapsed >= duration:
                break
            if transitions is not None and elapsed >= duration:
                raise RuntimeError("required real media transitions NOT_EXERCISED")
            time.sleep(sample_seconds)
        if not media or media["transitions"] < 2 or (not playback_only and media["sensed"] < 2):
            raise RuntimeError("alternating playback/accent consumer outcomes NOT_EXERCISED")
        if playback_only and any(s["media"] and (s["media"]["sensed"] or s["media"]["accentReady"]) for s in samples):
            raise RuntimeError("playback-only control unexpectedly sampled")
        if not playback_only and not frames.is_dir():
            raise RuntimeError("private frame-grab directory NOT_EXERCISED")
        self.unlock(cycle)
        if self.global_tmp_inventory() != tmp_before:
            raise RuntimeError("shared /tmp changed during a sampling run")
        summary = {"duration_seconds": samples[-1]["elapsed_seconds"], "samples": len(samples),
                   "outputs": outputs, "max_frame_files": max(s["frame_files"] for s in samples),
                   "global_tmp_unchanged": True,
                   "max_rss_bytes": max(s["rss_bytes"] for s in samples), "max_fds": max(s["fds"] for s in samples),
                   "minimum_mem_available_ratio": min(s["mem_available_kb"] / s["mem_total_kb"] for s in samples),
                   "media": media, "authenticated_exit0_desktop": True,
                   "resolution_lane": self.resource_label, "playback_only": playback_only}
        (self.resource_directory / "resource-result.json").write_text(json.dumps(summary, indent=2))
        # Preserve single-soak result paths for existing evidence consumers.
        if self.args.case == "sampling-soak":
            shutil.copyfile(self.resource_directory / "resource-samples.jsonl", self.output / "resource-samples.jsonl")
            shutil.copyfile(self.resource_directory / "resource-result.json", self.output / "resource-result.json")
        return summary

    def panel_snapshot(self, predicate, after=0, seconds=10):
        chosen = None
        def match(line):
            nonlocal chosen
            if "PANEL_SNAPSHOT " not in line:
                return False
            chosen = json.loads(line.split("PANEL_SNAPSHOT ", 1)[1])
            return predicate(chosen)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            for stamp, line in reversed(tuple(self.locker.lines)):
                if stamp >= after and match(line):
                    return chosen
            if self.locker.process.poll() is not None:
                break
            time.sleep(0.01)
        raise RuntimeError("panel consumer outcome NOT_EXERCISED")

    def hypr(self, *args):
        self.assert_control()
        return run(["hyprctl", *args], self.env, capture_output=True, text=True).stdout

    def start_pointer(self, output):
        self.assert_control()
        helper = Path(self.args.pointer_helper or self.root / "build/debug/aerial-tests/virtual-pointer-probe").resolve()
        if not helper.is_relative_to(self.root) or not helper.is_file():
            raise RuntimeError("owned VM pointer helper unavailable")
        self.owned.check_binary(helper)
        env = self.env.copy()
        env.pop("WAYLAND_DEBUG", None)
        self.pointer = subprocess.Popen([str(helper), output], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        import select
        if not select.select([self.pointer.stdout], [], [], 5)[0] \
                or self.pointer.stdout.readline().strip() != b"VIRTUAL_POINTER_READY":
            raise RuntimeError("native virtual pointer startup NOT_EXERCISED")

    def pointer_command(self, command, marker):
        self.assert_control()
        import select
        self.pointer.stdin.write((command + "\n").encode())
        self.pointer.stdin.flush()
        if not select.select([self.pointer.stdout], [], [], 5)[0] \
                or self.pointer.stdout.readline().strip() != marker:
            raise RuntimeError("native virtual pointer operation NOT_EXERCISED")

    def focus_hypr_input(self, output, seconds=5):
        monitors = json.loads(self.hypr("-j", "monitors"))
        target = next(m for m in monitors if m["name"] == output and not m.get("disabled", False))
        scale = float(target.get("scale", 1))
        assert scale > 0 and target["width"] > 0 and target["height"] > 0
        left, top = target["x"], target["y"]
        width, height = target["width"] / scale, target["height"] / scale
        # focusmonitor can return without warping an already-focused monitor.
        # Lock-surface mapping simulates mouse movement, so establish the actual
        # pointer rectangle as well as native monitor focus before launching qs.
        self.hypr("dispatch", "movecursor", f"{int(left + width / 2)} {int(top + height / 2)}")
        self.hypr("dispatch", "focusmonitor", output)
        deadline = time.monotonic() + seconds
        observed = None
        while time.monotonic() < deadline:
            pointer = json.loads(self.hypr("-j", "cursorpos"))
            monitors = json.loads(self.hypr("-j", "monitors"))
            current = next((m for m in monitors if m["name"] == output and not m.get("disabled", False)), None)
            observed = {"requested": target, "pointer": pointer,
                        "monitors": [{k: m.get(k) for k in ("name", "focused", "x", "y", "width", "height", "scale")} for m in monitors]}
            if current:
                current_scale = float(current.get("scale", 1))
                assert current_scale > 0
                current_left, current_top = current["x"], current["y"]
                current_width, current_height = current["width"] / current_scale, current["height"] / current_scale
                if current.get("focused", False) and current_left <= pointer["x"] < current_left + current_width \
                        and current_top <= pointer["y"] < current_top + current_height:
                    return
            time.sleep(0.01)
        raise RuntimeError("native monitor focus/pointer placement NOT_EXERCISED: " + json.dumps(observed))

    def wait_hypr_outputs(self, expected, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            monitors = json.loads(self.hypr("-j", "monitors"))
            names = {monitor["name"] for monitor in monitors
                     if not monitor.get("disabled", False) and monitor.get("width", 0) > 0}
            if names == expected:
                return names
            if self.locker.process.poll() is not None:
                break
            time.sleep(0.01)
        raise RuntimeError("required Hyprland enabled-output set NOT_EXERCISED: " + repr(expected))

    def panel_recover_hyprland(self, preserved, disable_outputs, add_output, recovery_output):
        # Hyprland creates a genuine headless output when its last normal
        # monitor goes away. Verify the panel there, then its migration to the
        # newly plugged output and withdrawal of FALLBACK by the compositor.
        stamp = time.monotonic_ns()
        disable_outputs()
        self.wait_hypr_outputs({"FALLBACK"})
        self.panel_snapshot(lambda s: s["output"] == "FALLBACK" and s["attached"]
                            and s["focused"] and s["hasVideo"] and s["backdropSameWindow"]
                            and preserved(s), after=stamp)
        stamp = time.monotonic_ns()
        add_output()
        self.wait_hypr_outputs({recovery_output})
        recovered = self.panel_snapshot(lambda s: s["output"] == recovery_output
                                        and s["attached"] and s["focused"] and s["hasVideo"]
                                        and s["backdropSameWindow"] and preserved(s), after=stamp)
        return recovered, "hyprland-fallback-to-new-output"

    def panel_recover_zero_outputs(self, preserved, disable_outputs, add_output, recovery_output):
        # Retain the no-usable-surface gate for backends without a fallback
        # output. A virtual fallback is not accepted as a parked panel here.
        stamp = time.monotonic_ns()
        disable_outputs()
        self.panel_snapshot(lambda s: s["output"] == "" and not s["attached"]
                            and preserved(s), after=stamp)
        stamp = time.monotonic_ns()
        add_output()
        recovered = self.panel_snapshot(lambda s: s["output"] == recovery_output
                                        and s["attached"] and s["focused"] and s["hasVideo"]
                                        and s["backdropSameWindow"] and preserved(s), after=stamp)
        return recovered, "zero-surface-park-and-recover"

    def panel_last_output_recovery(self, preserved, disable_outputs, add_output, recovery_output):
        if self.args.backend == "hyprland":
            return self.panel_recover_hyprland(preserved, disable_outputs, add_output, recovery_output)
        return self.panel_recover_zero_outputs(preserved, disable_outputs, add_output, recovery_output)

    def panel_failover(self, cycle):
        compositor_pid = self.compositor.process.pid
        compositor_starttime = Path(f"/proc/{compositor_pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
        instance = self.env["HYPRLAND_INSTANCE_SIGNATURE"]
        self.focus_hypr_input("remediation-1")
        self.launch(cycle)
        baseline = self.panel_snapshot(lambda s: s["output"] == "remediation-1" and s["focused"] and s["hasVideo"] and s["backdropSameWindow"])
        if self.pointer:
            self.pointer_command("map remediation-1", b"VIRTUAL_POINTER_MAPPED")
            # Establish the real seat's keyboard target through the same native
            # pointer interaction a user performs; preserve the auto-focus gate.
            self.pointer_command("click", b"VIRTUAL_POINTER_CLICKED")
        run(["wtype", "-d", "10", "-"], self.env, input=b"synthetic-failover-draft", stdout=subprocess.DEVNULL)
        run(["wtype", "-M", "shift", "-k", "Left", "-k", "Left", "-k", "Left", "-m", "shift"], self.env, stdout=subprocess.DEVNULL)
        saved = self.panel_snapshot(lambda s: s["syntheticDraft"] and s.get("cursor") == 21 and s.get("anchor") == 24)
        keys = ("cursor", "anchor", "revision", "writer", "generation", "policy", "scope", "latched", "initialWindowOpen")
        def preserved(snapshot):
            return snapshot["syntheticDraft"] and all(snapshot.get(k) == saved[k] for k in keys)
        stamp = time.monotonic_ns()
        self.hypr("output", "remove", "remediation-2")
        self.panel_snapshot(lambda s: s["output"] == "remediation-1" and preserved(s), after=stamp)
        self.hypr("output", "create", "headless", "remediation-2")
        self.hypr("keyword", "monitor", "remediation-2,1280x800@60,auto,1")
        stamp = time.monotonic_ns()
        if self.pointer:
            self.pointer_command("unmap", b"VIRTUAL_POINTER_UNMAPPED")
        self.hypr("output", "remove", "remediation-1")
        if self.pointer:
            selected = self.panel_snapshot(lambda s: s["output"] not in ("", "remediation-1") and preserved(s), after=stamp)
            self.pointer_command("map " + selected["output"], b"VIRTUAL_POINTER_MAPPED")
        survivor = self.panel_snapshot(lambda s: s["output"] not in ("", "remediation-1") and s["focused"] and s["backdropSameWindow"] and preserved(s), after=stamp)
        # Focus changes cannot repin the panel while its selected surface lives.
        third = "remediation-3" if getattr(self.args, "hyprland_virtual_outputs", False) else "WAYLAND-1"
        other = "remediation-2" if survivor["output"] == third else third
        stamp = time.monotonic_ns()
        self.hypr("dispatch", "focusmonitor", other)
        self.panel_snapshot(lambda s: s["output"] == survivor["output"] and preserved(s), after=stamp)
        monitors = json.loads(self.hypr("-j", "monitors"))
        def disable_outputs():
            for monitor in monitors:
                self.hypr("keyword", "monitor", monitor["name"] + ",disable")
        def add_output():
            self.hypr("output", "create", "headless", "remediation-recovery")
            self.hypr("keyword", "monitor", "remediation-recovery,1280x800@60,auto,1")
        recovered, recovery_path = self.panel_last_output_recovery(
            preserved, disable_outputs, add_output, "remediation-recovery")
        self.hypr("dispatch", "focusmonitor", "remediation-recovery")
        run(["wtype", "-M", "ctrl", "-k", "a", "-m", "ctrl", "-k", "BackSpace"], self.env, stdout=subprocess.DEVNULL)
        self.unlock(cycle)
        log = (self.output / f"locker-{cycle:03}.redacted.log").read_text()
        if log.count("REMEDIATION_THEME_CREATED") != 1 or log.count("REMEDIATION_THEME_DESTROYED") != 1:
            raise RuntimeError("theme/editor recreated during output migration")
        self.results[-1]["panel_preservation"] = {k: saved[k] for k in keys}
        self.results[-1]["output_recovered"] = recovered["output"]
        self.results[-1]["last_output_recovery"] = recovery_path
        self.results[-1]["compositor_pid"] = compositor_pid
        self.results[-1]["compositor_starttime"] = compositor_starttime
        self.results[-1]["compositor_instance"] = instance
        self.results[-1]["compositor_isolation"] = "fresh-per-cycle"
        self.results[-1]["normal_output_backend"] = "headless" if getattr(self.args, "hyprland_virtual_outputs", False) else "wayland-and-headless"
        self.results[-1]["native_pointer_device"] = self.pointer is not None
        (self.output / "cycles.json").write_text(json.dumps(self.results, indent=2))

    def unlock(self, cycle):
        submitted = self.type_and_submit()
        unlock = self.locker.wait_line(lambda line: ".unlock_and_destroy()" in line, 20)
        result = self.locker.finish(20)
        exited = time.monotonic_ns()
        if result != 0:
            raise RuntimeError("normal authentication/unlock exit=" + str(result))
        self.desktop()
        record = {"cycle": cycle, "exit": result, "unlock_and_destroy": True,
                  "submit_to_exit_ms": (exited - submitted) / 1e6,
                  "unlock_to_exit_ms": (exited - unlock) / 1e6, "desktop_input": True}
        self.results.append(record)
        (self.output / "cycles.json").write_text(json.dumps(self.results, indent=2))
        self.locker = None

    def blocked(self, reason):
        for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        record = {"status": "BLOCKED", "reason": reason, "driver_pid": os.getpid(),
                  "locker_pid": self.locker.process.pid,
                  "compositor_pid": self.compositor.process.pid if self.compositor else self.drm_pid,
                  "results": str(self.output)}
        (self.root / "run/BLOCKED.json").write_text(json.dumps(record, indent=2))
        print(json.dumps(record), flush=True)
        # Retain log drain, compositor and peer. Natural exit does not clear latch.
        while self.locker.process.poll() is None:
            time.sleep(1)
        return 125

    def cleanup(self):
        if self.locker and self.locker.process.poll() is None:
            if not getattr(self.args, "recover_owned_failures", False):
                return self.blocked("required full-caller outcome failed; no termination authorized")
            self.recover_owned_failure()
        if getattr(self, "drm_pid", None):
            self.restore_drm_outputs()
        if self.compositor and self.compositor.process.poll() is None:
            self.assert_control()
            self.compositor.process.terminate()  # owned nested compositor, no surviving qs
            self.compositor.finish(10)
        if getattr(self, "pointer", None):
            self.pointer.stdin.close()
            self.pointer.wait(timeout=5)
            self.pointer = None
        if getattr(self, "keyboard", None):
            if self.keyboard.poll() is None:
                self.keyboard.terminate()
            self.keyboard.wait(timeout=5)
            self.keyboard = None
        self.compositor = None
        return 0

    def recover_owned_failure(self):
        self.owned.authorize_recovery()
        self.assert_control()
        # Explicit test-only runner authorization. Failure results remain failed;
        # this is not a product unlock/recovery option and never touches a host.
        process = self.locker.process
        record = {"authorization": self.owned.record["recovery_authorization"],
                  "locker_pid": process.pid, "compositor_pid": self.compositor.process.pid if self.compositor else self.drm_pid,
                  "normal_auth_recovery": False, "forced_restart": False}
        try:
            run(["wtype", "-M", "ctrl", "-k", "a", "-m", "ctrl", "-k", "BackSpace"], self.env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.type_and_submit()
            self.locker.wait_line(lambda line: ".unlock_and_destroy()" in line, 20)
            record["normal_auth_recovery"] = self.locker.finish(20) == 0
        except (RuntimeError, subprocess.SubprocessError, OSError) as error:
            record["recovery_error"] = str(error)
        if process.poll() is None:
            record["forced_restart"] = True
            process.terminate()  # only this runner's directly owned VM child
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        self.locker.thread.join(2)
        record["exit"] = process.returncode
        (self.output / "failure-recovery.json").write_text(json.dumps(record, indent=2))
        self.locker = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--vm-record", required=True, help="operator-supplied owned VM/session manifest")
    parser.add_argument("--lane", choices=["debug"], required=True)
    parser.add_argument("--backend", choices=["niri", "hyprland", "sway", "niri-drm"], required=True)
    parser.add_argument("--case", required=True)
    parser.add_argument("--cycles", type=int, default=1)
    parser.add_argument("--outputs", type=int, default=1)
    parser.add_argument("--recover-owned-failures", action="store_true",
                        help="user-authorized VM child recovery/restart; failed cases remain failed")
    parser.add_argument("--hyprland-virtual-outputs", action="store_true",
                        help="three native virtual outputs; parent Wayland window stays disabled")
    parser.add_argument("--pointer-helper", help="VM-native persistent pointer fixture executable")
    parser.add_argument("--duration-seconds", type=int, default=7200)
    parser.add_argument("--sample-seconds", type=int, default=5)
    parser.add_argument("--resolutions", default="240,1080,2160")
    parser.add_argument("--transitions", type=int, default=100)
    parser.add_argument("--exit-budget-ms", type=int, default=250)
    args = parser.parse_args()
    if args.cycles < 1 or args.outputs < 1:
        parser.error("cycles/outputs must be positive")
    if args.sample_seconds < 1 or args.duration_seconds < 1 or args.transitions < 1:
        parser.error("duration, sampling interval and transitions must be positive")
    if args.exit_budget_ms != 250:
        parser.error("the approved connection-loss budget is 250 ms")
    try:
        args.resolutions = [int(value) for value in args.resolutions.split(",")]
        if not args.resolutions or any(value not in (240, 1080, 2160) for value in args.resolutions):
            raise ValueError
    except ValueError:
        parser.error("resolutions must be a comma-separated subset of 240,1080,2160")
    if args.hyprland_virtual_outputs and args.backend != "hyprland":
        parser.error("virtual-output lane requires --backend hyprland")
    session = Session(args)
    result = 1
    try:
        if args.case != "panel-failover":
            session.start()
        if args.case == "desktop-input-control":
            session.desktop()
            result = 0
            print(json.dumps({"case": args.case, "backend": args.backend, "desktop_input": True}), flush=True)
            return result
        if args.case == "panel-failover" and (args.backend != "hyprland" or args.outputs != 3):
            raise RuntimeError("panel-failover requires the specified three-output Hyprland lane")
        if args.case not in ("cold-load-and-media-fallback", "unlock", "early-unlock", "negative-auth", "screenshot-overlap", "prompt-state", "panel-failover", "sampling-soak", "sampling-scale", "connection-loss", "panel-zero-outputs"):
            raise RuntimeError("case acceptance not yet implemented: NOT_EXERCISED")
        if args.case == "negative-auth":
            if args.backend == "niri-drm":
                raise RuntimeError("the task's single negative-auth control already ran in the original fork")
            policy = (Path("/etc/pam.d") / session.owned.auth_fixture()["service"]).read_text()
            if "pam_faillock" in policy or "include" in policy or "pam_unix.so" not in policy:
                raise RuntimeError("unexpected fixture PAM policy")
            receipt = session.root / "run/negative-auth-attempt.json"
            if receipt.exists():
                raise RuntimeError("single negative-auth control already attempted; do not repeat")
        session.config(media=True)
        if args.case == "connection-loss":
            summary = session.connection_loss()
            result = 0
            print(json.dumps({"case": args.case, "results": str(session.output), "guard": summary}), flush=True)
            return result
        if args.case == "sampling-scale":
            summaries = []
            for resolution in args.resolutions:
                for playback_only in (True, False):
                    session.prepare_resource(resolution, playback_only)
                    summaries.append(session.resource_run(max(60, args.transitions * 12),
                        args.sample_seconds, args.transitions, playback_only))
                    (session.output / "scale-results.json").write_text(json.dumps(summaries, indent=2))
                    print(json.dumps({"resource_leg": summaries[-1]}), flush=True)
            result = 0
            print(json.dumps({"case": args.case, "results": str(session.output), "legs": len(summaries)}), flush=True)
            return result
        if args.case == "sampling-soak":
            session.prepare_resource()
            summary = session.resource_run(args.duration_seconds, args.sample_seconds)
            result = 0
            print(json.dumps({"case": args.case, "results": str(session.output), "resource": summary}), flush=True)
            return result
        if args.case == "panel-failover":
            session.prepare_panel()
        if args.case == "panel-zero-outputs":
            if args.backend not in ("sway", "niri-drm"):
                raise RuntimeError("genuine zero-output fixture requires a supported owned output-control lane")
            session.prepare_panel()
            for cycle in range(1, args.cycles + 1):
                if args.backend == "niri-drm": session.panel_zero_drm(cycle)
                else: session.panel_zero_outputs(cycle)
            result = 0
            print(json.dumps({"case": args.case, "results": str(session.output), "cycles": len(session.results)}), flush=True)
            return result
        if args.case == "prompt-state":
            session.prompt_fixture()
            result = 0
            print(json.dumps({"case": args.case, "assertions": 43, "exit": 0}), flush=True)
            return result
        for cycle in range(1, args.cycles + 1):
            if args.case == "panel-failover":
                session.start()
                session.panel_failover(cycle)
                # The full within-cycle hotplug/fallback/re-add flow has already
                # authenticated normally. Close only that unlocked owned nest;
                # the next cycle gets fresh compositor/output/input state.
                session.cleanup()
                continue
            if args.case == "cold-load-and-media-fallback":
                for leg, fault in enumerate((None, "core-create", "render-create")):
                    session.config(media=fault is not None)
                    session.launch(3 * cycle + leg, fault)
                    if fault:
                        marker = "FULL_CALLER_" + fault.replace("-", "_").upper() + "_FAULT"
                        session.locker.wait_line(lambda line: marker in line)
                        session.locker.wait_line(lambda line: "video background failed:" in line)
                    session.unlock(3 * cycle + leg)
                continue
            fault = "screenshot-write" if args.case == "screenshot-overlap" else None
            session.launch(cycle, fault)
            if args.case == "negative-auth":
                receipt.write_text(json.dumps({"attempted": True, "results": str(session.output)}))
                session.type_and_submit(wrong=True)
                # The stock native PAM IPC observes AuthFailed (2), not merely
                # elapsed time with a still-running authentication subprocess.
                session.locker.wait_line(lambda line: "Subprocess exited with code 2" in line, 15)
                if session.locker.process.poll() is not None or any(".unlock_and_destroy()" in line for _, line in tuple(session.locker.lines)):
                    raise RuntimeError("wrong response did not retain lock")
            elif args.case == "unlock":
                time.sleep(2)
            elif args.case == "screenshot-overlap":
                session.locker.wait_line(lambda line: "FULL_CALLER_SCREENSHOT_WRITE_HELD" in line)
            session.unlock(cycle)
            if args.case == "screenshot-overlap":
                logfile = session.output / f"locker-{cycle:03}.redacted.log"
                if "FULL_CALLER_SCREENSHOT_WRITE_RELEASED" in logfile.read_text():
                    raise RuntimeError("screenshot overlap ended before locker exit: NOT_EXERCISED")
        result = 0
        print(json.dumps({"case": args.case, "cycles": len(session.results), "results": str(session.output), "exit": 0}), flush=True)
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        observed = session.locker.process if session.locker else None
        (session.output / "failure-state.json").write_text(json.dumps({"case": args.case,
            "reason": str(error), "observed_pid": observed.pid if observed else None,
            "observed_exit": observed.poll() if observed else None}, indent=2))
        print("REMEDIATION_FAILED " + str(error), file=sys.stderr, flush=True)
    finally:
        cleanup = session.cleanup()
        if cleanup:
            result = cleanup
        (session.output / "result.json").write_text(json.dumps({"case": args.case,
            "exit": result, "cycles_exercised": len(session.guard_outcomes) // 9
            if args.case == "connection-loss" else len(session.results)}, indent=2))
    return result


if __name__ == "__main__":
    sys.exit(main())
