#!/usr/bin/env python3
"""Incremental native builds follow install paths and compiler configuration."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve(strict=True)
with tempfile.TemporaryDirectory(prefix="aerial-build-config-") as d:
    root = Path(d)
    tree = root / "source"
    shutil.copytree(source, tree, ignore=shutil.ignore_patterns(".git", "build", "__pycache__", "*.so"))

    def make(prefix, *args):
        result = subprocess.run(["make", "-C", str(tree), "PREFIX=" + str(prefix), *args],
                                capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr

    a, b = root / "a", root / "b"
    make(a, "clean")
    make(a)
    objects = sorted((tree / "build").glob("*.o"))
    assert len(objects) == 5, objects
    before = [p.stat().st_mtime_ns for p in objects]
    make(b, "install", "PAMDIR=" + str(root / "pam"))
    after = [p.stat().st_mtime_ns for p in objects]
    assert all(new > old for old, new in zip(before, after)), "install-path changes reused native objects"

    # Observe the installed supervisor consuming its compiled defaults; no
    # env overrides and no real locker. The old prefix was never installed.
    marker = root / "runner-args.json"
    runner = b / "libexec/aerial-lock/aerial-lock-run"
    runner.write_text("#!/usr/bin/python3\nimport json,sys\nfrom pathlib import Path\n"
                      f"Path({str(marker)!r}).write_text(json.dumps(sys.argv[1:]))\n")
    runner.chmod(0o700)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(root / "wayland"))
    listener.listen(16)
    env = {k: v for k, v in os.environ.items()
           if k not in ("AERIAL_LOCK_RUNNER", "AERIAL_LOCK_SHELL", "AERIAL_LOCK_PLUGIN_ROOT",
                        "AERIAL_LOCK_VIDEO_POOL", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_SOCKET")}
    env.update(WAYLAND_DISPLAY=str(root / "wayland"), XDG_RUNTIME_DIR=str(root))
    result = subprocess.run(["dbus-run-session", "--", str(b / "bin/aerial-lock-supervisor")],
                            env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(marker.read_text()) == ["--shell-dir", str(b / "share/aerial-lock"),
                                              "--plugin-root", str(b / "lib/aerial-lock/qt-plugins")]
    listener.close()
    make(b)
    assert after == [p.stat().st_mtime_ns for p in objects], "unchanged configuration rebuilt native objects"
    make(b, "CXXFLAGS=-O1 -frecord-gcc-switches")
    assert all(p.stat().st_mtime_ns > old for p, old in zip(objects, after)), "changed flags reused native objects"
    print("BUILD_CONFIG_PASS paths_consumed_by_installed_supervisor stable_noop flags_rebuilt")
