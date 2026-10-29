#!/usr/bin/env python3
"""Owned-VM manifest and real UNIX-listener ownership regressions; no QS/PAM."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

from owned_instance import OwnedInstance, socket_identity

MANIFEST = None


class ListenerOwnership(unittest.TestCase):
    def test_native_session_survives_unrelated_descriptor_churn(self):
        import owned_instance
        pid = os.getpid()
        disappeared = []
        def readlink(path):
            if str(path).startswith(f"/proc/{pid}/fd/") and not disappeared:
                disappeared.append(str(path))
                raise FileNotFoundError(str(path))
            return "/dev/dri/card1"
        runtime = Path("/run/user") / str(os.getuid())
        with patch("owned_instance.os.readlink", side_effect=readlink), \
                patch("owned_instance.process_identity", return_value={"pid":pid}), \
                patch("owned_instance.socket_identity", side_effect=lambda path,pid:{"path":str(path)}), \
                patch.object(Path,"read_bytes",return_value=b"niri\0--session\0"):
            # The disappearing non-DRM descriptor must not cause inspection to
            # abort; the actual native-DRM requirement remains a separate gate.
            result = owned_instance.session_identity(pid,"niri-drm",runtime,"wayland-fixture",runtime/"ipc-fixture")
        self.assertEqual(result["drm_devices"], ["/dev/dri/card1"])
        self.assertEqual(len(disappeared), 1)

    def test_listener_owned_by_recorded_process(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket(socket.AF_UNIX) as listener:
            path = Path(directory) / "display.sock"
            listener.bind(str(path))
            listener.listen()
            result = socket_identity(path, os.getpid())
            self.assertEqual(result["path"], str(path))
            self.assertEqual(result["inode"], path.stat().st_ino)

    def test_accepted_peer_with_same_path_does_not_replace_listener_identity(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket(socket.AF_UNIX) as listener:
            path = Path(directory) / "display.sock"
            listener.bind(str(path))
            listener.listen()
            initial = socket_identity(path, os.getpid())
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(path))
                peer, _ = listener.accept()
                with peer:
                    rows = [line for line in Path("/proc/net/unix").read_text().splitlines()
                            if line.split()[-1] == str(path)]
                    self.assertGreaterEqual(len(rows), 2, "duplicate bound-path trigger absent")
                    self.assertEqual(socket_identity(path, os.getpid()), initial)

    def test_same_socket_path_without_matching_compositor_descriptor_is_refused(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket(socket.AF_UNIX) as listener:
            path = Path(directory) / "display.sock"
            listener.bind(str(path))
            listener.listen()
            with patch("owned_instance.os.readlink", return_value="pipe:[0]"):
                with self.assertRaisesRegex(RuntimeError, "not owned"):
                    socket_identity(path, os.getpid())


class ManifestOwnership(unittest.TestCase):
    def setUp(self):
        self.original = json.loads(MANIFEST.read_text())
        self.root = Path(self.original["paths"]["root"])
        handle = tempfile.NamedTemporaryFile(dir=self.root / "run", prefix="owned-negative-", delete=False)
        self.path = Path(handle.name)
        handle.close()

    def tearDown(self):
        self.path.unlink()

    def fixture(self, mutate=lambda record: None):
        record = copy.deepcopy(self.original)
        mutate(record)
        self.path.write_text(json.dumps(record))
        return OwnedInstance(self.path, self.root)

    def test_real_manifest_matches_current_guest_source_and_native_session(self):
        owned = self.fixture()
        self.assertEqual(owned.check_session(owned.record["session"], owned.record["environment"]),
                         owned.record["session"])

    def test_prepared_base_domain_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "prepared base"):
            self.fixture(lambda record: record.update(domain=record["base_domain"]))

    def test_mismatched_domain_uuid_attestation_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "attestation"):
            self.fixture(lambda record: record.update(uuid="00000000-0000-4000-8000-000000000001"))

    def test_wrong_device_mac_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "device identity"):
            self.fixture(lambda record: record.update(mac="52:54:00:00:00:01"))

    def test_another_boot_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "boot identity"):
            self.fixture(lambda record: record["guest"].update(boot_id="not-this-boot"))

    def test_wrong_source_bytes_are_refused_even_with_recomputed_inventory_identity(self):
        def change(record):
            key = next(iter(record["source_files"]))
            record["source_files"][key]["sha256"] = "0" * 64
            record["current_source_identity"] = hashlib.sha256(json.dumps(record["source_files"], sort_keys=True).encode()).hexdigest()
        with self.assertRaisesRegex(RuntimeError, "source hash/mode drift"):
            self.fixture(change)

    def test_wrong_source_mode_is_refused(self):
        def change(record):
            key = next(iter(record["source_files"]))
            record["source_files"][key]["mode"] ^= 0o100
            record["current_source_identity"] = hashlib.sha256(json.dumps(record["source_files"], sort_keys=True).encode()).hexdigest()
        with self.assertRaisesRegex(RuntimeError, "source hash/mode drift"):
            self.fixture(change)

    def test_reused_compositor_pid_with_other_starttime_is_refused(self):
        owned = self.fixture()
        wrong = copy.deepcopy(owned.record["session"])
        wrong["process"]["starttime"] = "0"
        with self.assertRaisesRegex(RuntimeError, "ownership changed"):
            owned.check_session(wrong, owned.record["environment"])

    def test_another_control_display_is_refused(self):
        owned = self.fixture()
        env = dict(owned.record["environment"], WAYLAND_DISPLAY="wayland-unowned")
        with self.assertRaisesRegex(RuntimeError, "another session"):
            owned.check_session(owned.record["session"], env)

    def test_absent_binary_provenance_is_refused_before_product_launch(self):
        owned = self.fixture(lambda record: record.update(binary_hashes={}))
        with self.assertRaisesRegex(RuntimeError, "binary provenance"):
            owned.check(require_binaries=True)

    def test_sequential_runs_with_the_same_case_and_timestamp_have_distinct_roots(self):
        spec = importlib.util.spec_from_file_location("owned_run_driver", Path(__file__).with_name("remediation-driver.py"))
        driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(driver)
        case = "owned-identity-regression-" + uuid.uuid4().hex
        def args(backend):
            return SimpleNamespace(root=str(self.root), vm_record=str(MANIFEST),
                                   case=case, backend=backend, recover_owned_failures=False)
        # Constructors validate real ownership but start no compositor/locker.
        with patch.dict(os.environ, self.original["environment"]), \
                patch.object(driver.time, "strftime", return_value="same-second"):
            first = driver.Session(args("niri"))
            second = driver.Session(args("hyprland"))
            third = driver.Session(args("niri"))
        self.assertEqual(len({first.output, second.output, third.output}), 3)
        self.assertTrue(all(item.output.is_dir() for item in (first, second, third)))


class RecoveryAuthorization(unittest.TestCase):
    def fixture(self, authorization):
        owned = OwnedInstance.__new__(OwnedInstance)
        owned.record = {"uuid": "fixture-uuid", "recovery_authorization": authorization}
        return owned

    def test_default_recovery_is_not_authorized(self):
        with self.assertRaisesRegex(RuntimeError, "explicit user authorization"):
            self.fixture(None).authorize_recovery()

    def test_another_instances_approval_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "explicit user authorization"):
            self.fixture({"uuid":"another-uuid", "mode":"recover-owned-failures",
                          "user_approval_reference":"current-user-approval"}).authorize_recovery()

    def test_missing_approval_reference_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "explicit user authorization"):
            self.fixture({"uuid":"fixture-uuid", "mode":"recover-owned-failures"}).authorize_recovery()

    def test_current_instance_explicit_approval_is_required(self):
        approval = {"uuid":"fixture-uuid", "mode":"recover-owned-failures",
                    "user_approval_reference":"current-user-approval"}
        self.assertEqual(self.fixture(approval).authorize_recovery(), approval)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vm-record", required=True, type=Path)
    args, remaining = parser.parse_known_args()
    MANIFEST = args.vm_record
    unittest.main(argv=[__file__, *remaining], verbosity=2)
