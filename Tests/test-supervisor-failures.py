#!/usr/bin/env python3
"""Exit-status timing distinguishes a refused lock from uncertain engagement."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

supervisor = Path(sys.argv[1]).resolve(strict=True)
runner_path = Path(sys.argv[2]).resolve(strict=True)
cases = [
    ("pre-engagement", [72, 72, 72], 3, "the lock never engaged; the screen is NOT locked"),
    ("monitor", [71, 71, 71], 3, "lock engagement not confirmed; the screen may be unlocked"),
    ("abnormal-then-monitor", [70, 71, 71], 3, "lock engagement not confirmed; the screen may be unlocked"),
    ("monitor-then-startup", [71, 72, 72], 3, "lock engagement not confirmed; the screen may be unlocked"),
    ("abnormal-then-startup", [70, 72, 72], 3, "lock engagement not confirmed; the screen may be unlocked"),
    ("abnormal", [70, 70, 70], 2, "NO automatic unlock"),
    ("unlock", [0], 0, "clean exit — done"),
    ("missing-runner", None, 3, "the lock never engaged; the screen is NOT locked"),
    ("missing-plugin", None, 3, "the lock never engaged; the screen is NOT locked"),
    ("missing-qs", None, 3, "the lock never engaged; the screen is NOT locked"),
    ("shell-not-found", [127, 127, 127], 3, "the lock never engaged; the screen is NOT locked"),
    ("shell-not-executable", [126, 72, 127], 3, "the lock never engaged; the screen is NOT locked"),
    ("abnormal-then-not-found", [70, 127, 127], 3, "lock engagement not confirmed; the screen may be unlocked"),
]


def tools_dir(root):
    """A PATH entry with only what the runner needs, so no installed qs is found."""
    tools = root / "tools"
    if not tools.exists():
        tools.mkdir()
        for tool in ("bash", "mkdir", "chmod", "rm", "rmdir"):
            (tools / tool).symlink_to(shutil.which(tool))
    return tools


def run_runner(root, name, args, path_entries, runtime=None):
    """Run the real runner directly with a controlled PATH and fake qs."""
    case = root / ("runner-" + name)
    case.mkdir()
    shell = case / "shell"
    shell.mkdir()
    plugins = case / "plugins" / "generic"
    plugins.mkdir(parents=True)
    (plugins / "libAerialLockConnectionGuard.so").write_bytes(b"")
    bin_dir = case / "bin"
    bin_dir.mkdir()
    for entry, content, mode in path_entries:
        (bin_dir / entry).write_text(content)
        (bin_dir / entry).chmod(mode)
    marker = case / "qs-ran"
    env = {"PATH": str(bin_dir) + ":" + str(tools_dir(root)), "HOME": str(case), "QS_MARKER": str(marker)}
    if runtime is not None:
        env["XDG_RUNTIME_DIR"] = str(runtime)
    argv = [str(runner_path)] + [a.format(shell=shell, plugins=plugins.parent) for a in args]
    result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=15)
    return result, marker


def runner_cases(root):
    fake_qs = "#!/bin/sh\nprintf '%s' \"${AERIAL_LOCK_RUNTIME_DIR-unset}\" > \"$QS_MARKER\"\nexit 0\n"
    normal = ["--shell-dir", "{shell}", "--plugin-root", "{plugins}"]
    # Every way the runner can stop before its exec reports "never engaged".
    for name, args, entries, text in (
            ("no-qs", normal, [], "qs is not available"),
            ("qs-not-executable", normal, [("qs", fake_qs, 0o600)], "qs is not available"),
            ("qs-bad-interpreter", normal, [("qs", "#!/nonexistent/interpreter\n", 0o700)], "qs could not be executed"),
            ("missing-option-value", ["--shell-dir"], [("qs", fake_qs, 0o700)], ""),
            ("unknown-option", ["--bogus"], [("qs", fake_qs, 0o700)], "unknown argument")):
        result, marker = run_runner(root, name, args, entries)
        assert result.returncode == 72, (name, result.returncode, result.stderr)
        assert text in result.stderr, (name, result.stderr)
        assert not marker.exists(), name
        print("RUNNER_PRE_EXEC_FAILURE_PASS", name)
    # The frame-grab directory is optional: an unusable runtime directory never
    # stops the lock, it only leaves accent sampling off.
    blocked = root / "runtime-not-a-directory"
    blocked.write_text("")
    result, marker = run_runner(root, "runtime-unusable", normal, [("qs", fake_qs, 0o700)], runtime=blocked)
    assert result.returncode == 0 and marker.read_text() == "unset", (result.returncode, result.stderr)
    print("RUNNER_OPTIONAL_RUNTIME_DIR_PASS")
with tempfile.TemporaryDirectory(prefix="aerial-failures-") as directory:
    root = Path(directory)
    runner_cases(root)
    for name, codes, expected, message in cases:
        case = root / name
        case.mkdir()
        # Accepting the connection is enough for the supervisor's liveness
        # check; no session-lock request is issued by these synthetic runners.
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(case / "wayland"))
        listener.listen(16)
        stub = case / "runner"
        if codes is not None:
            stub.write_text("#!/usr/bin/python3\nfrom pathlib import Path\n"
                            f"p = Path({str(case / 'count')!r})\n"
                            "n = int(p.read_text()) if p.exists() else 0\n"
                            "p.write_text(str(n + 1))\n"
                            f"raise SystemExit({codes!r}[n])\n")
            stub.chmod(0o700)
        env = {k: v for k, v in os.environ.items()
               if k not in ("HYPRLAND_INSTANCE_SIGNATURE", "AERIAL_LOCK_VIDEO_POOL", "WAYLAND_SOCKET")}
        env.update(WAYLAND_DISPLAY=str(case / "wayland"), XDG_RUNTIME_DIR=str(case),
                   AERIAL_LOCK_RUNNER=str(runner_path if name in ("missing-plugin", "missing-qs") else stub),
                   AERIAL_LOCK_PLUGIN_ROOT=str(case / "missing"), AERIAL_LOCK_SHELL=str(case))
        if name == "missing-qs":
            # The real runner with valid paths, on a PATH without qs.
            (case / "plugins" / "generic").mkdir(parents=True)
            (case / "plugins" / "generic" / "libAerialLockConnectionGuard.so").write_bytes(b"")
            env.update(AERIAL_LOCK_PLUGIN_ROOT=str(case / "plugins"), PATH=str(tools_dir(root)))
        result = subprocess.run([shutil.which("dbus-run-session"), "--dbus-daemon=" + shutil.which("dbus-daemon"),
                                 "--", str(supervisor)], env=env,
                                capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        assert result.returncode == expected, (name, result.returncode, output)
        assert message in output, (name, output)
        assert output.count("launching locker, attempt") == (1 if name == "unlock" else 3), output
        if expected == 3:
            assert "staying locked" not in output, output
        if name in ("missing-plugin", "missing-qs"):
            # The real runner must run and refuse, not fail to start.
            assert "child process error" not in output, output
            assert output.count("child finished: exit=72") == 3, output
        if codes is not None and 71 in codes:
            assert "the lock never engaged" not in output, output
        listener.close()
        print("SUPERVISOR_FAILURE_PASS", name)
