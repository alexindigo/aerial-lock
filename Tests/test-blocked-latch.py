#!/usr/bin/env python3
"""Run on the owned VM. No QS, compositor, or credential is involved."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="aerial-latch-") as directory:
    root = Path(directory)
    (root / "run").mkdir()
    process = subprocess.Popen([sys.argv[1], "--latch-harness", str(root)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert select.select([process.stderr], [], [], 5)[0], "BLOCKED not exercised"
    line = process.stderr.readline().decode()
    assert "BLOCKED_QS_PID" in line, line
    receipts = list((root / "run").glob("blocked-qs-*.json"))
    assert len(receipts) == 1, "missing persistent receipt"
    receipt = json.loads(receipts[0].read_text())
    assert receipt["status"] == "BLOCKED" and receipt["probe_pid"] == process.pid
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        os.kill(process.pid, sig)
    stdout, stderr = process.communicate(timeout=10)
    assert process.returncode == 3, (process.returncode, stderr)
    assert "exit=0; result remains BLOCKED" in stderr.decode(), stderr
    assert receipts[0].exists(), "BLOCKED latch silently cleared"
    print("BLOCKED_LATCH_OUTCOME signals_ignored=3 relay_echoes=20 child_exit=0 result=BLOCKED")
