#!/usr/bin/env python3
"""Bundled idle defaults follow the lock shell override or compiled DATADIR."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve(strict=True)
with tempfile.TemporaryDirectory(prefix="idle-shell-dir-") as directory:
    root = Path(directory)
    tree = root / "source"
    shutil.copytree(source, tree, ignore=shutil.ignore_patterns(".git", "build", "__pycache__", "*.so"))
    defaults = json.loads((source / "Config/defaults.json").read_text())

    def bundle(name, timeout):
        shell = root / name
        (shell / "Config").mkdir(parents=True)
        value = json.loads(json.dumps(defaults))
        value["idle"]["timeoutSeconds"] = timeout
        (shell / "Config/defaults.json").write_text(json.dumps(value))
        return shell, value["idle"]

    compiled, compiled_idle = bundle("compiled", 17)
    override, override_idle = bundle("override shell", 73)
    result = subprocess.run(["make", "-C", str(tree), "clean"],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run(["make", "-C", str(tree), "idle/aerial-idle", "DATADIR=" + str(compiled)],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / "empty-config"),
               QT_FORCE_STDERR_LOGGING="1", LC_ALL="C.UTF-8")
    env.pop("AERIAL_LOCK_SHELL", None)

    def read(value, cwd=None):
        case_env = dict(env)
        if value is not None:
            case_env["AERIAL_LOCK_SHELL"] = value
        return subprocess.run([str(tree / "idle/aerial-idle"), "--print-config"], env=case_env,
                              cwd=cwd, capture_output=True, text=True, timeout=5)

    # Start with the override: the old reader ignores it and returns 17.
    for label, value, expected in (("override", str(override), override_idle),
                                    ("unset", None, compiled_idle), ("empty", "", compiled_idle),
                                    ("source", str(source), defaults["idle"])):
        result = read(value)
        assert result.returncode == 0 and not result.stderr, (label, result.stdout, result.stderr)
        assert json.loads(result.stdout) == expected, (label, result.stdout, expected)
        print("IDLE_SHELL_DIR", label, expected, flush=True)

    for value in (".", "./Config/../."):
        result = read(value, cwd=override)
        assert result.returncode == 0 and not result.stderr, (value, result.stdout, result.stderr)
        assert json.loads(result.stdout) == override_idle, (value, result.stdout, override_idle)
        print("IDLE_SHELL_DIR relative", value, override_idle, flush=True)

    # An explicit shell is authoritative, never silently replaced by DATADIR.
    missing = root / "missing-shell"
    result = read(str(missing))
    assert result.returncode != 0 and not result.stdout, (result.stdout, result.stderr)
    assert str(missing / "Config/defaults.json") in result.stderr, result.stderr
    print("IDLE_SHELL_DIR missing override rejected; all resolution cases passed")
