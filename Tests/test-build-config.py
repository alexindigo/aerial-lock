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
from private_runtime import PrivateRuntime

source = Path(sys.argv[1]).resolve(strict=True)
with tempfile.TemporaryDirectory(prefix="aerial-build-config-") as d, PrivateRuntime("wayland") as runtime:
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
    assert {p.name for p in objects} == {
        "aerial-unlock-main.o", "aerial-unlock-proto.o",
        "aerial-supervisor-main.o", "aerial-supervisor-proto.o",
        "aerial-idle-main.o", "aerial-idle-proto.o", "connection-guard.o", "surface-input.o"
    }, objects
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
    listener.bind(str(runtime / "wayland"))
    listener.listen(16)
    env = {k: v for k, v in os.environ.items()
           if k not in ("AERIAL_LOCK_RUNNER", "AERIAL_LOCK_SHELL", "AERIAL_LOCK_PLUGIN_ROOT",
                        "AERIAL_LOCK_VIDEO_POOL", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_SOCKET")}
    env.update(WAYLAND_DISPLAY=str(runtime / "wayland"), XDG_RUNTIME_DIR=str(runtime))
    result = subprocess.run(["dbus-run-session", "--", str(b / "bin/aerial-lock-supervisor")],
                            env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(marker.read_text()) == ["--shell-dir", str(b / "share/aerial-lock"),
                                              "--plugin-root", str(b / "lib/aerial-lock/qt-plugins")]
    # The companion must consume its new compiled data path too, rather than
    # a stale prefix or a user-config override. --print-config opens no bus.
    idle_env = dict(env, XDG_CONFIG_HOME=str(root / "empty-config"))
    result = subprocess.run([str(b / "bin/aerial-idle"), "--print-config"], env=idle_env,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stdout + result.stderr
    defaults = json.loads((b / "share/aerial-lock/Config/defaults.json").read_text())
    assert json.loads(result.stdout) == defaults["idle"]
    listener.close()
    make(b)
    assert after == [p.stat().st_mtime_ns for p in objects], "unchanged configuration rebuilt native objects"
    make(b, "CXXFLAGS=-O1 -frecord-gcc-switches")
    assert all(p.stat().st_mtime_ns > old for p, old in zip(objects, after)), "changed flags reused native objects"

    # The installed unit must use the same configured binary directory as the
    # native companion, never DESTDIR or a fixed distribution prefix.
    for label, prefix, bindir in (("default", Path("/usr"), Path("/usr/bin")),
                                  ("prefix", Path("/usr/local"), Path("/usr/local/bin")),
                                  ("bindir", Path("/usr/local"), Path("/opt/aerial/bin"))):
        stage = root / (label + "-stage")
        options = ["DESTDIR=" + str(stage)]
        if label == "bindir":
            options.append("BINDIR=" + str(bindir))
        make(prefix, "install", *options)
        unit = stage / prefix.relative_to("/") / "lib/systemd/user/aerial-idle.service"
        commands = [line for line in unit.read_text().splitlines() if line.startswith("ExecStart=")]
        assert commands == [f"ExecStart={bindir}/aerial-idle"], (label, commands)
        assert unit.stat().st_mode & 0o777 == 0o644, (label, oct(unit.stat().st_mode))
        assert (stage / bindir.relative_to("/") / "aerial-idle").is_file()
        print(f"UNIT_INSTALL_PASS {label} {commands[0]} mode=644", flush=True)
        make(prefix, "uninstall", *options)
        assert not any(p.is_file() for p in stage.rglob("*")), f"{label} uninstall left installed files"

    # Exercise the distributor's code-generation phase too. With LTO, Qt's
    # position-independence requirement must survive the final executable link,
    # not just the initial compilation. Arch's flags are the package-build
    # contract; other distributions still exercise the same LTO boundary.
    packaging_config = Path("/etc/makepkg.conf")
    if packaging_config.is_file():
        result = subprocess.run(["bash", "--noprofile", "--norc", "-c",
            'source "$1"; printf "%s\\0" "$CFLAGS $LTOFLAGS" '
            '"$CXXFLAGS $LTOFLAGS" "$LDFLAGS $LTOFLAGS"', "bash", str(packaging_config)],
            capture_output=True, timeout=10, check=True)
        packaging_flags = result.stdout.decode().split("\0")[:3]
    else:
        packaging_flags = ["-O2 -flto", "-O2 -flto", "-flto"]
    assert len(packaging_flags) == 3 and all("-flto" in value for value in packaging_flags)
    flags = [key + "=" + value for key, value in
             zip(("CFLAGS", "CXXFLAGS", "LDFLAGS"), packaging_flags)]
    print("PACKAGING_LTO_FLAGS " + json.dumps(flags), flush=True)
    make(b, "clean")
    make(b, *flags)
    result = subprocess.run([str(tree / "idle/aerial-idle"), "--print-config"], env=idle_env,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout) == defaults["idle"]
    print("BUILD_CONFIG_PASS paths_consumed_by_installed_supervisor_and_idle stable_noop flags_rebuilt unit_install_paths packaging_lto")
