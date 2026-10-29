#!/usr/bin/env python3
"""Exit-status timing distinguishes a refused lock from uncertain engagement."""
import os
from pathlib import Path
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
]
with tempfile.TemporaryDirectory(prefix="aerial-failures-") as directory:
    root = Path(directory)
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
                   AERIAL_LOCK_RUNNER=str(runner_path if name == "missing-plugin" else stub),
                   AERIAL_LOCK_PLUGIN_ROOT=str(case / "missing"), AERIAL_LOCK_SHELL=str(case))
        result = subprocess.run(["dbus-run-session", "--", str(supervisor)], env=env,
                                capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        assert result.returncode == expected, (name, result.returncode, output)
        assert message in output, (name, output)
        assert output.count("launching locker, attempt") == (1 if name == "unlock" else 3), output
        if expected == 3:
            assert "staying locked" not in output, output
        if codes is not None and 71 in codes:
            assert "the lock never engaged" not in output, output
        listener.close()
        print("SUPERVISOR_FAILURE_PASS", name)
