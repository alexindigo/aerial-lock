#!/usr/bin/env python3
"""Task-owned VM/session validation for test drivers, never product runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import stat
import uuid


def digest(path):
    path = Path(path)
    payload = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
    return hashlib.sha256(payload).hexdigest()


def process_identity(pid):
    process = Path("/proc") / str(pid)
    return {"pid": int(pid), "uid": process.stat().st_uid,
            "starttime": process.joinpath("stat").read_text().rsplit(")", 1)[1].split()[19],
            "executable": str(process.joinpath("exe").resolve(strict=True))}


def socket_identity(path, pid):
    path = Path(path)
    metadata = path.stat()
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise RuntimeError("session socket type/owner mismatch: " + str(path))
    # The filesystem inode and socket inode are different namespaces. Observe
    # the kernel socket table and the compositor's FDs, not just pathname presence.
    rows = [line.split() for line in Path("/proc/net/unix").read_text().splitlines()[1:]]
    # Accepted stream peers also retain the bound pathname. Only the listener
    # carries __SO_ACCEPTCON (1 << 16); peer churn must not change its identity.
    inodes = {row[6] for row in rows if len(row) == 8 and row[7] == str(path)
              and row[4] == "0001" and int(row[3], 16) & (1 << 16)}
    descriptors = set()
    for descriptor in (Path("/proc") / str(pid) / "fd").iterdir():
        try:
            descriptors.add(os.readlink(descriptor))
        except FileNotFoundError:
            pass
    if len(inodes) != 1 or "socket:[" + next(iter(inodes)) + "]" not in descriptors:
        raise RuntimeError("socket is not owned by recorded compositor: " + str(path))
    return {"path": str(path), "device": metadata.st_dev, "inode": metadata.st_ino,
            "socket_inode": next(iter(inodes))}


def session_identity(pid, backend, runtime, wayland, ipc):
    runtime = Path(runtime)
    wayland = Path(wayland) if str(wayland).startswith("/") else runtime / wayland
    ipc = Path(ipc)
    if not wayland.is_relative_to(runtime) or not ipc.is_relative_to(runtime):
        raise RuntimeError("session sockets must be inside the recorded runtime directory")
    record = {"process": process_identity(pid), "backend": backend, "runtime": str(runtime),
              "wayland": socket_identity(wayland, pid), "ipc": socket_identity(ipc, pid)}
    if backend == "niri-drm":
        process = Path("/proc") / str(pid)
        if b"--session" not in process.joinpath("cmdline").read_bytes().split(b"\0"):
            raise RuntimeError("native DRM lane requires the actual session compositor")
        devices = set()
        for descriptor in process.joinpath("fd").iterdir():
            try:
                target = os.readlink(descriptor)
            except FileNotFoundError:
                continue
            if target.startswith("/dev/dri/card"):
                devices.add(target)
        record["drm_devices"] = sorted(devices)
        if not record["drm_devices"]:
            raise RuntimeError("native DRM device ownership not observed")
    return record


class OwnedInstance:
    def __init__(self, path, root):
        self.path = Path(path).resolve(strict=True)
        self.root = Path(root).resolve(strict=True)
        metadata = self.path.stat()
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise RuntimeError("VM manifest must be caller-owned mode 0600")
        self.record = json.loads(self.path.read_text())
        # Host, domain and base identities come from the operator's manifest;
        # nothing here names a particular lab, host or VM.
        if self.record.get("version") != 1 or not self.record.get("host"):
            raise RuntimeError("requires a version-1 owned VM manifest naming its host")
        domain = self.record["domain"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", domain) \
                or not self.record.get("base_domain") or domain == self.record["base_domain"]:
            raise RuntimeError("prepared base or unknown feature identity refused")
        uuid.UUID(self.record["uuid"])
        if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", self.record["mac"]):
            raise RuntimeError("invalid feature MAC")
        if not self.path.is_relative_to(self.root / "run"):
            raise RuntimeError("manifest is outside the owned run root")
        self.paths = {key: Path(value) for key, value in self.record["paths"].items()}
        required = {"root", "source", "build", "stage", "run", "results", "media"}
        if set(self.paths) != required or self.paths["root"] != self.root:
            raise RuntimeError("incomplete or mismatched workspace roots")
        for path in self.paths.values():
            if not path.is_absolute() or not path.is_relative_to(self.root) or path.resolve() != path:
                raise RuntimeError("workspace escape or symlink refused: " + str(path))
            if path.stat().st_uid != os.getuid():
                raise RuntimeError("unowned workspace: " + str(path))
        ownership = self.record["ownership"]
        if str(self.root) not in ownership["task_created"] or ownership["pre_existing"]:
            raise RuntimeError("workspace was not recorded as fresh and task-owned")
        self.check()

    def check(self, require_binaries=False):
        guest = self.record["guest"]
        if guest["uid"] != os.getuid() or guest["user"] != pwd.getpwuid(os.getuid()).pw_name:
            raise RuntimeError("guest account/UID mismatch")
        if not self.root.is_relative_to(Path.home()) or self.root == Path.home():
            raise RuntimeError("workspace must be a private child of the guest home")
        if Path("/proc/sys/kernel/random/boot_id").read_text().strip() != guest["boot_id"]:
            raise RuntimeError("guest boot identity changed; operator must rediscover the session")
        macs = {path.read_text().strip() for path in Path("/sys/class/net").glob("*/address")}
        if self.record["mac"] not in macs:
            raise RuntimeError("guest device identity does not match owned domain")
        # Domain UUID is bound to this MAC/boot by the host's recorded libvirt
        # inspection; guest product_uuid is root-readable, not an invented check.
        if self.record["host_identity"]["uuid"] != self.record["uuid"] \
                or self.record["host_identity"]["mac"] != self.record["mac"]:
            raise RuntimeError("host domain/device attestation mismatch")
        if not re.fullmatch(r"[0-9a-f]{64}", self.record["source_freeze_identity"]):
            raise RuntimeError("missing source-freeze identity")
        source = self.record["source_files"]
        if not source:
            raise RuntimeError("empty source inventory")
        if hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest() \
                != self.record["current_source_identity"]:
            raise RuntimeError("source inventory identity mismatch")
        for relative, expected in source.items():
            path = self.paths["source"] / relative
            if not path.is_relative_to(self.paths["source"]) or ".." in Path(relative).parts:
                raise RuntimeError("source inventory escape")
            if digest(path) != expected["sha256"] or path.lstat().st_mode != expected["mode"]:
                raise RuntimeError("source hash/mode drift: " + relative)
        if require_binaries and (not self.record["binary_hashes"] or
                self.record["binary_source_identity"] != self.record["current_source_identity"]):
            raise RuntimeError("missing/current-source binary provenance")
        for absolute, expected in self.record["binary_hashes"].items():
            path = Path(absolute)
            if not path.is_relative_to(self.root) or digest(path) != expected:
                raise RuntimeError("binary ownership/hash drift: " + absolute)
        for pattern in ("BLOCKED.json", "blocked-qs-*.json"):
            if list(self.paths["run"].glob(pattern)):
                raise RuntimeError("persistent BLOCKED latch; inspection/permission required")
        return self.record

    def check_binary(self, path):
        path = Path(path).resolve(strict=True)
        expected = self.record["binary_hashes"].get(str(path))
        if not path.is_relative_to(self.root) or expected is None or digest(path) != expected:
            raise RuntimeError("requested binary is not in the owned build manifest: " + str(path))
        return path

    def check_session(self, record, env):
        process = record["process"]
        if process_identity(process["pid"]) != process or process["uid"] != os.getuid():
            raise RuntimeError("compositor PID/starttime/executable ownership changed")
        current = session_identity(process["pid"], record["backend"], record["runtime"],
                                   record["wayland"]["path"], record["ipc"]["path"])
        if current != record:
            raise RuntimeError("compositor sockets/device identity changed")
        runtime = Path(env.get("XDG_RUNTIME_DIR", ""))
        display = env.get("WAYLAND_DISPLAY", "")
        display = Path(display) if display.startswith("/") else runtime / display
        if runtime != Path(record["runtime"]) or display != Path(record["wayland"]["path"]):
            raise RuntimeError("control environment belongs to another session")
        if record["backend"].startswith("niri") and env.get("NIRI_SOCKET") != record["ipc"]["path"]:
            raise RuntimeError("Niri IPC environment mismatch")
        return record

    def auth_fixture(self):
        fixture = self.record.get("pam_fixture")
        if not fixture or not fixture.get("prepared") or fixture.get("uuid") != self.record["uuid"] \
                or fixture.get("uid") != os.getuid() or not fixture.get("operator_session"):
            raise RuntimeError("real authentication requires the prepared owned credential fixture")
        service = fixture["service"]
        if not re.fullmatch(r"[A-Za-z0-9._-]+", service):
            raise RuntimeError("invalid fixture PAM service")
        secret = Path(fixture["secret_file"])
        if secret != self.paths["run"] / "pam-fixture-secret" or secret.is_symlink():
            raise RuntimeError("credential fixture escaped the owned run root")
        metadata = secret.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() \
                or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise RuntimeError("credential fixture ownership/mode mismatch")
        service_path = Path("/etc/pam.d") / service
        if service_path.stat().st_uid != 0 or service_path.read_text() != "auth required pam_unix.so\n":
            raise RuntimeError("fixture PAM policy mismatch")
        return fixture

    def authorize_recovery(self):
        authorization = self.record["recovery_authorization"]
        if not authorization or authorization.get("uuid") != self.record["uuid"] \
                or not authorization.get("user_approval_reference") \
                or authorization.get("mode") != "recover-owned-failures":
            raise RuntimeError("owned recovery requires current explicit user authorization in the manifest")
        return authorization


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--vm-record", required=True)
    parser.add_argument("--session-record")
    args = parser.parse_args()
    owned = OwnedInstance(args.vm_record, args.root)
    owned.check(require_binaries=True)
    session = owned.record["session"]
    if args.session_record:
        path = Path(args.session_record).resolve(strict=True)
        if not path.is_relative_to(owned.paths["results"]):
            raise RuntimeError("child session record outside owned results")
        wrapper = json.loads(path.read_text())
        if wrapper["instance_uuid"] != owned.record["uuid"]:
            raise RuntimeError("child session belongs to another instance")
        session = wrapper["session"]
    owned.check_session(session, os.environ)
    print("OWNED_VM_SESSION_VALIDATED " + owned.record["domain"])


if __name__ == "__main__":
    main()
