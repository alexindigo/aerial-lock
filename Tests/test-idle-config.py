#!/usr/bin/env python3
"""Execute ConfigStore's actual pure merge/repair methods and the native reader.

The QML source methods are loaded verbatim, excluding the component's startup
I/O. Both consumers receive each fixture's exact same serialized objects.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
source = Path(__file__).resolve().parent.parent
runner = sys.argv[2]
defaults = json.loads((source / "Config/defaults.json").read_text())
qml = (source / "Services/ConfigStore.qml").read_text()


def method(name):
    # Methods are top-level declarations indented four spaces. End at the next
    # top-level function/comment, keeping the original body exactly as shipped.
    start = qml.index("    function " + name + "(")
    end = qml.index("\n    }", start) + len("\n    }")
    return qml[start:end]


methods = "\n".join(method(name) for name in
                    ("isPlainObject", "deepMerge", "matchesType", "sanitise", "warnSubtree", "checkBundle"))
schema_start = qml.index("    readonly property var schema: (") + len("    readonly property var schema: (")
schema = qml[schema_start:qml.index("\n    })", schema_start) + len("\n    }")]
with tempfile.TemporaryDirectory(prefix="idle-config-") as directory:
    root = Path(directory)
    (root / "logger.js").write_text('.pragma library\nfunction w(tag, message) { console.warn(tag + ": " + message) }\n')
    for fixture in json.loads((source / "Tests/fixtures/idle-config.json").read_text()):
        config = root / fixture["name"] / "aerial-lock"
        config.mkdir(parents=True)
        if not fixture.get("missing"):
            (config / "config.json").write_text(json.dumps(fixture["user"]))
        env = dict(os.environ, XDG_CONFIG_HOME=str(config.parent), QT_QPA_PLATFORM="offscreen",
                   QT_FORCE_STDERR_LOGGING="1", LC_ALL="C.UTF-8", AERIAL_LOCK_SHELL=str(source))
        native = subprocess.run([str(binary), "--print-config"], env=env,
                                capture_output=True, text=True, timeout=10)
        assert native.returncode == 0, (fixture["name"], native.stdout, native.stderr)
        effective = json.loads(native.stdout)
        warnings = fixture.get("warnings", 0)
        assert native.stderr.count("using default") == warnings, native.stderr
        test = root / "tst_idle_config.qml"
        test.write_text('''import QtQuick
import QtTest
import "logger.js" as Logger
TestCase {
    name: "IdleConfigParity"
''' + methods + '''
    function test_fixture() {
        failOnWarning(/.*/)
        var defaults = ''' + json.dumps(defaults) + '''
        var user = ''' + json.dumps(fixture.get("user", {})) + '''
        var schema = ''' + schema + '''
        verify(checkBundle(defaults, schema, ""))
        var merged = deepMerge(defaults, user)
        for (var i = 0; i < ''' + str(warnings) + '''; i++) ignoreWarning(/ConfigStore: idle\\..*using default/)
        sanitise(merged, defaults, schema, "")
        compare(merged.idle, ''' + json.dumps(effective) + ''')
        // Arrays and scalar overrides replace, while object siblings survive.
        compare(JSON.stringify(deepMerge({ a: {x: 1, y: [1,2]} }, { a: {y: [3]} })),
                JSON.stringify({a:{x:1,y:[3]}}))
        compare(JSON.stringify(deepMerge({a:{x:1}}, {a:false})), JSON.stringify({a:false}))
    }
}
''')
        result = subprocess.run([runner, "-input", str(test)], env=env,
                                capture_output=True, text=True, timeout=30)
        print(result.stdout, end="")
        assert result.returncode == 0 and not re.search(r"^QWARN\s*:", result.stdout, re.M), (result.stdout, result.stderr)
        print("IDLE_CONFIG", fixture["name"], "native=ConfigStore", effective)
    print("IDLE_CONFIG all shared fixtures passed")
