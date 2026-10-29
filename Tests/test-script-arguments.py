#!/usr/bin/env python3
"""User operands must reach tools as data, including expression-looking names."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

source = Path(sys.argv.pop(1)).resolve(strict=True)


class LiteralArguments(unittest.TestCase):
    def test_lint_roots_are_literal(self):
        for name in ("-delete", "-exec", "(", "!", "space dir", "line\nbreak", "-one.qml"):
            with self.subTest(name=name), tempfile.TemporaryDirectory(prefix="aerial-args-") as d:
                root = Path(d)
                operand = root / name
                if name.endswith(".qml"):
                    qml = operand
                else:
                    operand.mkdir()
                    qml = operand / "Fixture.qml"
                qml.write_text("import QtQuick\nItem {}\n")
                sentinel = root / "keep"
                sentinel.write_text("must survive")
                result = subprocess.run(["bash", str(source / "Scripts/dev/qmllint.sh"), name],
                                        cwd=root, capture_output=True, text=True, timeout=20)
                self.assertTrue(sentinel.exists(), result.stderr)
                self.assertTrue(qml.exists(), result.stderr)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Linting 1 QML files", result.stdout)

    def test_missing_lint_root_is_an_error(self):
        with tempfile.TemporaryDirectory(prefix="aerial-args-") as d:
            result = subprocess.run(["bash", str(source / "Scripts/dev/qmllint.sh"), "-missing"],
                                    cwd=d, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_fetch_url_cannot_supply_curl_options(self):
        with tempfile.TemporaryDirectory(prefix="aerial-args-") as d:
            root = Path(d)
            manifest = root / "private-manifest.json"
            manifest.write_text('{"assets": []}')
            options = root / "options.json"
            options.write_text(f'url = "{manifest.as_uri()}"\n')
            config = root / "config/aerial-lock"
            config.mkdir(parents=True)
            (config / "config.json").write_text(json.dumps({"preferredResolution": 1080,
                "sources": [{"type": "community", "name": "Fixture", "source": "--config=" + str(options)}]}))
            env = dict(os.environ, XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"))
            result = subprocess.run(["sh", str(source / "Scripts/aerial-lock-fetch")], env=env,
                                    capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "cache/aerial-lock/Fixture/entries.json").exists(),
                             "URL operand was executed as curl --config, reading the private fixture")

    def test_nested_output_count_is_not_an_expression(self):
        with tempfile.TemporaryDirectory(prefix="aerial-args-") as d:
            root = Path(d)
            for tool in ("niri", "ghostty"):
                stub = root / tool
                stub.write_text("#!/bin/sh\nexit 0\n")
                stub.chmod(0o700)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"])
            for count in ("1+0", "0", "-1", "x[$(false)]"):
                result = subprocess.run(["bash", str(source / "Scripts/dev/nested.sh"),
                                         "niri", "--outputs", count], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2, count + result.stdout + result.stderr)


unittest.main()
