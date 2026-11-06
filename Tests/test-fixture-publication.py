#!/usr/bin/env python3
"""Pause the generated idle runner after open, before any payload write."""
import ast
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

from fixture_files import publish
from private_runtime import PrivateRuntime

source = Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory(prefix="fixture-publish-") as directory, PrivateRuntime("report") as runtime:
    root = Path(directory)
    # Use the real generated runner without starting the idle integration suite.
    tree = ast.parse((source / "Tests/test-idle-logind.py").read_text())
    case = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "Case")
    init = next(n for n in case.body if isinstance(n, ast.FunctionDef) and n.name == "__init__")
    expression = next(n.value.args[0] for n in ast.walk(init)
                      if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
                      and isinstance(n.value.func, ast.Attribute) and n.value.func.attr == "write_text"
                      and isinstance(n.value.func.value, ast.Attribute) and n.value.func.value.attr == "runner")
    runner = root / "runner"
    runner.write_text(eval(compile(ast.Expression(expression), "<actual runner template>", "eval"),
                           {"self": SimpleNamespace(root=root), "source": source}))
    bootstrap = root / "bootstrap.py"
    bootstrap.write_text('''import io, os, runpy, sys
original = io.open
def paused_open(*args, **kwargs):
    stream = original(*args, **kwargs)
    name = os.readlink('/proc/self/fd/' + str(stream.fileno()))
    base = os.path.basename(name)
    if base == 'received' or (base.startswith('.received.') and base != '.received.lock'):
        print('OPEN ' + name, flush=True)
        assert sys.stdin.readline() == 'continue\\n'
    return stream
io.open = paused_open
sys.argv = [sys.argv[1], '--shell-dir', 'fixture']
runpy.run_path(sys.argv[0], run_name='__main__')
''')
    (root / "engage").touch()
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(runtime / "report"))
        listener.listen(1)
        listener.settimeout(8)
        child = subprocess.Popen([sys.executable, str(bootstrap), str(runner)],
                                 env=dict(os.environ, AERIAL_LOCK_ENGAGEMENT_SOCKET=str(runtime / "report")),
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            connection, _ = listener.accept()
            with connection:
                assert connection.recv(1024) == b"locked\n"
                connection.sendall(b"release\n")
                assert select.select([child.stdout], [], [], 8)[0], "writer reached paused open"
                print(child.stdout.readline().strip(), flush=True)
                target = root / "received"
                visible = target.exists()
                observed = target.read_bytes() if visible else None
                print("CONSUMER_WHILE_WRITER_PAUSED", visible, repr(observed), flush=True)
                child.stdin.write("continue\n"); child.stdin.flush()
                assert child.wait(8) == 0, child.stderr.read()
                assert not visible, "existence signalled completion before the writer wrote release"
                assert target.read_bytes() == b"release\n"
        finally:
            if child.poll() is None:
                child.stdin.write("continue\n"); child.stdin.flush()
                (root / "stop").touch()
                child.wait(8)

    # An updating journal must retain its complete previous snapshot until the
    # new one is published; failed replacement must not expose or lose data.
    journal = root / "launches"
    publish(journal, "first\n")
    replace = os.replace
    def observe_replace(temporary, target):
        assert target == journal
        assert target.read_bytes() == b"first\n"
        assert temporary.read_bytes() == b"first\nsecond\n"
        assert list(root.glob("launches*")) == [journal]
        replace(temporary, target)
    with patch("fixture_files.os.replace", side_effect=observe_replace):
        publish(journal, "second\n", append=True)
    assert journal.read_bytes() == b"first\nsecond\n"
    with patch("fixture_files.os.replace", side_effect=OSError("injected replace failure")):
        try:
            publish(journal, "third\n", append=True)
        except OSError as error:
            assert str(error) == "injected replace failure"
        else:
            raise AssertionError("publication swallowed replacement failure")
    assert journal.read_bytes() == b"first\nsecond\n"
    assert list(root.glob(".launches.*")) == [root / ".launches.lock"], "failed publication left staging files"

    # All peers start before any writer is released. Concurrent appends must
    # retain every record, including duplicates the supervisor tests detect.
    peers = [subprocess.Popen([sys.executable, "-c",
             "import sys; from fixture_files import publish; sys.stdin.readline(); "
             "publish(sys.argv[1], sys.argv[2] + '\\n', append=True)", str(journal), str(i)],
             env=dict(os.environ, PYTHONPATH=str(source / "Tests")), stdin=subprocess.PIPE, text=True)
             for i in range(8)]
    for peer in peers:
        peer.stdin.write("go\n"); peer.stdin.close()
    for peer in peers:
        assert peer.wait(8) == 0
    assert sorted(journal.read_text().splitlines()) == sorted(["first", "second", *map(str, range(8))])
    print("FIXTURE_PUBLICATION paused runner, snapshots, failure preservation and concurrent appends passed")
