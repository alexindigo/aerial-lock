# QML suites

Run in the project's authorized test VM, with a disk-backed `TMPDIR`:

```sh
QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=opengl LIBGL_ALWAYS_SOFTWARE=1 \
  /usr/lib/qt6/bin/qmltestrunner -import Tests/imports -input Tests/tst_theme_host.qml
```

The same invocation supports every `Tests/tst_*.qml` suite. The test-only
`imports/Quickshell` modules let standalone QtTest load ThemeHost's types
without Quickshell's executable-linked plugins. They supply only its inactive
I/O boundary; any environment or file access throws. The handoff suite loads
the actual ThemeHost, Loader, timers, AuthInputState and candidate QML, while
driving a synthetic writer's composition and explicit release. Real native
IME handling belongs to the native input probe; real theme discovery and
Quickshell loading belong to the nested-shell camera gate.

The accent-sampler suite writes its frame files into `TMPDIR`; point it at a
disposable directory.

# Native tests

```sh
cmake -S Tests -B build/aerial-tests -G Ninja -DAERIAL_LOCK_SOURCE="$PWD"
cmake --build build/aerial-tests
ctest --test-dir build/aerial-tests --output-on-failure
```

Run `make` first: `supervisor-session` uses the built supervisor. The portable
set covers native input and editor migration, the BLOCKED latch, supervisor
session scoping, media-failure fallback (an injected core failure) and the
output-selection policy. `-DAERIAL_LOCK_VM_RECORD=<manifest>` adds the
`owned-instance` regression for a prepared VM (below).

# VM integration drivers

`run-remediation.sh` (→ `remediation-driver.py`), `launch-integration.py` and
`nested-launch-integration.py` run real locks with real PAM inside owned nested
compositors (or a recorded native DRM session) of a disposable test VM. They
never run on a desktop session. Every run takes `--root <workspace>` and
`--vm-record <manifest>`.

Workspace layout under the root: `src/aerial-lock` (the tree under test),
`build/debug/aerial-tests` (the CMake build above), `stage` (`make install
DESTDIR=<root>/stage`), `run`, `results`, `media`.

```sh
bash Tests/run-remediation.sh --root "$ROOT" --lane debug --vm-record "$VM_RECORD" \
  --backend niri --case unlock --cycles 50
```

Cases: `cold-load-and-media-fallback`, `prompt-state`, `negative-auth` (run it
once; it counts against the account's lockout), `unlock`, `early-unlock`,
`screenshot-overlap`, `connection-loss` (`--exit-budget-ms 250`),
`sampling-scale` (`--resolutions 240,1080,2160 --transitions 100
--sample-seconds 5`), `sampling-soak`, `panel-failover` (Hyprland,
`--outputs 3 --hyprland-virtual-outputs`) and, on `--backend niri-drm`,
`desktop-input-control` and `panel-zero-outputs`.

The Hyprland virtual-output lane uses stock render-backed headless outputs; it
proves lock behavior on virtual outputs, not physical-display presentation.
`virtual-pointer-probe` uses the version-2 wlr protocol in `virtual-pointer.xml`
(upstream MIT notice retained). Native input is distinct from Qt synthetic
events and from real platform IME composition. Passwords reach the locker only
through stdin of the input tool; protocol traffic is filtered before anything
is written to disk.

A failed locker that is still running is never killed: the driver writes a
`run/BLOCKED.json` / `run/blocked-qs-*.json` latch, keeps its compositor and
refuses later runs until someone inspects it. `--recover-owned-failures` allows
recovery only when the manifest also carries a matching
`recovery_authorization`; a failed attempt stays failed.

`connection-loss` runs the guard cases through a byte-preserving relay that
cuts only the locker's first Wayland connection: blocked-GUI, logger,
video, retirement and exit-trap cases must exit 70 within 250 ms; arming and
monitor fault injections must exit 71. All fault hooks live in test-only
preload libraries; the product has no fault or debug-exit setting.

`sampling-scale` checks the original budgets (RSS ≤ 1 GiB, FDs < 75 % of the
limit, MemAvailable ≥ 25 %), that the private frame directory never holds more
files than there are outputs, and that the shared `/tmp` is unchanged.

## Owned manifest

A mode-0600 JSON file under `<root>/run/`, owned by the caller, written by the
operator who prepared the VM. `owned_instance.py` validates it before any
launch or control and refuses every mismatch; there is no fallback.

| # | Field | Content |
|---|---|---|
| 1 | `version` | `1` |
| 2 | `host`, `domain`, `base_domain` | VM host, the disposable test domain, and the prepared base it was cloned from (which is refused as a target) |
| 3 | `uuid`, `mac` | Domain UUID and MAC; the MAC must be present in the guest |
| 4 | `host_identity` | `{uuid, mac}` as observed from the host's hypervisor |
| 5 | `guest` | `{user, uid, boot_id}` of the current boot |
| 6 | `paths` | Absolute `root`, `source`, `build`, `stage`, `run`, `results`, `media`, all inside `root`, caller-owned, no symlinks |
| 7 | `ownership` | `{task_created: [root, …], pre_existing: []}` |
| 8 | `source_freeze_identity` | SHA-256 identifying the delivered source snapshot |
| 9 | `source_files` | `{relative path: {sha256, mode}}` of the tree under `paths.source` |
| 10 | `current_source_identity` | SHA-256 of `json.dumps(source_files, sort_keys=True)` |
| 11 | `binary_hashes`, `binary_source_identity` | SHA-256 of each built/staged binary the drivers execute, and the source identity they were built from |
| 12 | `session` | The outer compositor: `process {pid, uid, starttime, executable}`, `backend`, `runtime`, `wayland` and `ipc` listener identities (from `owned_instance.session_identity`) |
| 13 | `environment` | `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `NIRI_SOCKET` of that session |
| 14 | `initial_outputs` | Mapped output names at preparation time |
| 15 | `pam_fixture` | `{prepared, uuid, uid, operator_session, service, secret_file}`; the service file is exactly `auth required pam_unix.so`, the secret is `<run>/pam-fixture-secret` (0600) |
| 16 | `recovery_authorization` | `null`, or `{uuid, mode: "recover-owned-failures", user_approval_reference}` |

Any source transfer invalidates the binary hashes: rebuild and re-record them
before a product run.
