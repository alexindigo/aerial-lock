# Testing aerial-lock

Build and test in a disposable VM with the runtime/build dependencies from the
README, including installed **qt6-mpvqml ≥ 0.2.0**. Use a disk-backed workspace
and temporary directory. The commands below run inside that guest from the
repository root:

```sh
mkdir -p "$HOME/aerial-test/tmp"
export TMPDIR="$HOME/aerial-test/tmp"
export LIBGL_ALWAYS_SOFTWARE=1 QSG_RHI_BACKEND=opengl
make DEBUG_DISMISS=0 DEBUG_VERBOSE=0
```

## Portable checks

```sh
bash Scripts/dev/qmllint.sh .
node --test Tests/theme-selection.test.cjs Tests/theme-attribution.test.cjs
```

### QML suites

```sh
mkdir -p "$TMPDIR/qml-gate"
log="$TMPDIR/qml-gate/qmltestrunner.log"
status=0
QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=opengl LIBGL_ALWAYS_SOFTWARE=1 \
  /usr/lib/qt6/bin/qmltestrunner -import Tests/imports -input Tests >"$log" 2>&1 || status=$?
cat "$log"
qwarnings=$(awk '/^QWARN[[:space:]]*:/ { count++ } END { print count+0 }' "$log")
printf 'Whole-log QWARN count: %s\n' "$qwarnings"
test "$status" -eq 0 && test "$qwarnings" -eq 0
```

The gate requires both a successful test exit and **zero QWARNs in the whole
log**, for every suite. Keep the same log check when selecting a single suite:
construction and teardown warnings occur outside test functions and can escape
`failOnWarning()`. Every `Connections` declares its target at construction; bind
to a nullable context while it is unavailable instead of relying on the implicit
parent target or assigning `target` later in `init()`.

Locate component internals by a unique, component-scoped `objectName` (using
QtTest's `findChild` or a name-only traversal when counting instances). Assert
visibility, geometry, text and interface properties only after selecting the
named object; those mutable properties must not decide which object is tested.

Use `-input Tests/tst_theme_host.qml` to select just one suite. The test-only
`imports/Quickshell` modules let standalone QtTest load ThemeHost's types
without Quickshell's executable-linked plugins. They supply only its inactive
I/O boundary; any environment or file access throws. The handoff suite loads
the actual ThemeHost, Loader, timers, AuthInputState and candidate QML, while
driving a synthetic writer's composition and explicit release. Real native
IME handling belongs to the native input probe; real theme discovery and
Quickshell loading belong to the nested-shell camera gate.

The accent-sampler suite writes its frame files into `TMPDIR`; point it at a
disposable directory. Auth-input tests fail on warnings, and destroy consumers
before their context. Theme fidelity includes a markup-bearing PAM message on
all five themes and the fallback; glyph layout must match plain-text rendering.

### Native tests

One layout serves these tests and the VM drivers below: a workspace `$ROOT`
with the tree under test at `$ROOT/src/aerial-lock` and the test build at
`$ROOT/build/debug/aerial-tests`.

```sh
make -C "$ROOT/src/aerial-lock"
cmake -S "$ROOT/src/aerial-lock/Tests" -B "$ROOT/build/debug/aerial-tests" -G Ninja \
  -DAERIAL_LOCK_SOURCE="$ROOT/src/aerial-lock"
cmake --build "$ROOT/build/debug/aerial-tests"
ctest --test-dir "$ROOT/build/debug/aerial-tests" --output-on-failure
```

`make` comes first: `supervisor-session` uses the built supervisor. The portable
set covers native input and editor migration, the BLOCKED latch, supervisor
session scoping and engagement-confirmed duplicates (waiting while engaging, a
dead locker's lost confirmation, ignored foreign reports, never-engaging and
failing supervisors, and `dbus-test-tool` name owners that do not answer or
answer malformed; it also uses `busctl`), pre-engagement/monitor/mixed and
engaged-then-abnormal supervisor outcomes, literal shell
operands, incremental build configuration, driver wait ordering, media-failure
fallback (an injected core failure; `media-fallback-render` needs a platform
that renders video, e.g. inside a nested compositor: it is reported as skipped
only on the `offscreen`/`minimal` Qt platforms or a non-OpenGL Qt Quick
backend, and fails anywhere else if video does not start) and output-selection
policy. `-DAERIAL_LOCK_VM_RECORD=<manifest>` adds the `owned-instance`
regression for a prepared VM (below).

`build-config` also rebuilds every native target with LTO. On Arch it sources
`CFLAGS`, `CXXFLAGS`, `LDFLAGS` and `LTOFLAGS` from `/etc/makepkg.conf`; elsewhere
it uses a minimal optimized LTO build. This exercises Qt's protected-data-symbol
contract at final link, as well as compilation, and checks the rebuilt idle
executable's effective config. Existing path-change, no-op and compiler-flag
invalidation checks still run first. Staged installs check the unit generated
from `systemd/aerial-idle.service.in` with the default prefix, `/usr/local`,
and an explicit `BINDIR` override: `ExecStart` must name the installed binary
without `DESTDIR`, the unit must have mode 644, and uninstall must remove the
payload in each layout.

`supervisor-release` uses a private bus and stub direct-child runners to
observe exactly `release\n`, pending engagement, D-Bus/SIGUSR1 parity,
idempotence, no respawn after clean or abnormal release, a waiting duplicate's
SIGUSR1 immunity (exit 0/4 unchanged), and the child's unblocked SIGUSR1 mask.
Its terminal probe pumps the production Supervisor after normal episode
completion, without entering `app.exec()`, to check the actual
`org.aeriallock.Supervisor.Error.NotLocked` reply for ended/failed states;
there is no product test switch. Offscreen `tst_engagement_report.qml` checks
the exact command and one-warning policy at the inactive transport boundary.

`idle-config` compares the native reader's `--print-config` output with the
actual ConfigStore merge/schema methods in QML for shared fixtures: missing,
partial, full and invalid objects/fields, extra keys and timeout bounds.
Both idle fixtures set `AERIAL_LOCK_SHELL` to the source tree, so no installed
`/usr/share/aerial-lock` is needed. This variable selects both the supervisor's
shell directory and aerial-idle's bundled `Config/defaults.json`; unset or empty
uses the compiled `DATADIR`. `idle-shell-dir` builds with a private compiled
bundle, observes a different timeout from a scratch shell override, checks unset
and empty fallback, reads the source bundle and rejects an unavailable override.
`idle-logind` uses private system/session buses, fake login1/systemd peers and
the real supervisor with a stub runner. It checks lock deduplication, unlock
forwarding, real inhibitor-FD lifetime through confirmation/deadline/resume,
login1 replacement (including replacement without an old resume and failed
state snapshots), bypass-started locks, typed transient-unit arguments and
detached process ancestry. The fake systemd merges its explicit manager
environment with the unit's `Environment`, then applies `UnsetEnvironment`
after parsing all properties. A stale manager shell override is replaced by a
nonempty daemon override or removed when the daemon's override is unset/empty;
the unset property must have D-Bus type `as`. Both launch paths
check the shell override seen by the launched process and the supervisor's
actual shell operand, including unset/empty compiled fallback without `/usr`.
Relative `.` and paths containing `..` are resolved against the daemon's cwd
once, then reach both child launch paths as the same absolute, cleaned path.
The relative-bundle print-config probe observes its distinct timeout, and a
direct supervisor caller also checks relative operand normalization.
Daemon termination must leave the independent
lock alive. Each policy switch and compositor-disconnect exit are covered.
Private runtime sockets use a shared short namespace under `TMPDIR`, with
encoded-path length preflight before launching a fixture.

## Real-session integration drivers

Stock wtype 0.4 writes its keymap to a hardcoded shared temporary path, ignoring
`TMPDIR`. For disk-backed-only guest testing, put a workspace-local build with
the TMPDIR-only tempfile patch first in `PATH`; preserve its source, patch and
binary hash with the operator evidence. No system wtype replacement is needed.

`run-remediation.sh` (→ `remediation-driver.py`), `launch-integration.py` and
`nested-launch-integration.py` run real locks with real PAM inside owned nested
compositors (or a recorded native DRM session) of a disposable test VM. They
never run on a desktop session. Every run takes `--root <workspace>` and
`--vm-record <manifest>`.

Workspace layout under the root: `src/aerial-lock` (the tree under test),
`build/debug/aerial-tests` (built exactly as in "Native tests" above), `stage`
(`make -C "$ROOT/src/aerial-lock" install DESTDIR="$ROOT/stage"`), `run`,
`results`, `media`. `ROOT` below names that disk-backed guest workspace and
`VM_RECORD` its operator-produced manifest.

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

Stock Fcitx visible-echo candidate popups and nested Hyprland synthetic input
remain limitations (README). A portable native-input probe exercises injected
Qt IME events, not a real platform candidate popup. Do not conflate those results.

A failed locker that is still running is never killed: the driver writes a
`run/BLOCKED.json` / `run/blocked-qs-*.json` latch, keeps its compositor and
refuses later runs until someone inspects it. `--recover-owned-failures` allows
recovery only when the manifest also carries a matching
`recovery_authorization`; a failed attempt stays failed.

`connection-loss` runs the guard cases through a byte-preserving relay that
cuts only the locker's first Wayland connection: blocked-GUI, logger,
video, retirement and exit-trap cases must exit 70 within 250 ms; arming and
monitor fault injections exit 72 and 71 respectively. The supervisor's
`supervisor-failures` regression checks pre-engagement, monitor and mixed
attempt outcomes and every pre-exec runner failure (exit 72): exhausted guard
failures exit 3 and never claim a screen state the supervisor cannot know. All fault hooks live in test-only
preload libraries; the product has no fault or debug-exit setting.

`sampling-scale` checks the original budgets (RSS ≤ 1 GiB, FDs < 75 % of the
limit, MemAvailable ≥ 25 %), that the private frame directory never holds more
files than there are outputs, and that the shared `/tmp` is unchanged.

`launch-integration.py --root "$ROOT" --vm-record "$VM_RECORD"` checks the
staged installed supervisor, same-PID runner, real-PAM unlock and failed starts
(missing runner/plugin, arming and monitor faults). A duplicate supervisor for
the same session runs beside each on a private bus: beside the real lock it
must report waiting while engaging and exit 0 only after the locker's
confirmation; beside each failed start it must exit 4. `--stage` can select a second
install prefix inside the workspace. `nested-launch-integration.py` checks the
development template with `--backend niri --vm-key` (emulated guest keyboard)
or `--backend hyprland --ipc-control` (compositor spawn path, not native keys).

`surface-input-integration.py --root "$ROOT" --vm-record "$VM_RECORD" --case <case>`
requires a recorded native niri DRM session with two mapped outputs. Niri's
nested winit backend has only one output and cannot reproduce output hotplug.
Run each of `non-panel`, `hotplug`, `fast` and `compose`. These cover ordinary
non-panel input, output removal/re-addition, native typing across at least ten
focus transfers and stock Fcitx inline dead-key composition at focus-out. The
inline engine avoids the documented unsupported CJK candidate-popup path. Each case observes
the pinned panel's exact synthetic draft before stopping diagnostics, then real
PAM unlock on the non-panel surface, natural exit 0 and desktop input. The QML surface
suite covers selection, masking, consume/clear, busy/limit/tuning behavior,
immediate first-key authority, gesture cancellation, rapid focus roundtrips and
both theme-handoff orders; the native-input probe adds two real QQuickWindows
and the native commit-before-focus-in ordering, including a key delivered
before native focus-in. `surface-input-filter` separately checks scope, FIFO,
exactly-once replay, key metadata, the 64-event/250-ms bounds, count-only logging,
destruction cleanup and non-interception of input-method events. Real platform composition and
fast cross-output input are exercised in the real-session driver.

`native-input-sink-panel` injects public `QInputMethodEvent` preedit/commit
events into the actual editor. It attaches the panel to a composing sink's
native window and checks retained native focus, writer/generation and preedit,
continued composition, no submission on composing Return, one commit revision,
then panel authority. The QML suites check fallback/theme declarative focus,
pending-focus cancellation, writer retirement and commit-with-new-preedit ordering. These are synthetic Qt
editor-contract checks. Real Fcitx/Mozc sink-to-panel composition is the IME
experiment's M3 regression after rebasing onto this fix; master cannot provide
that proof while its stock candidate-popup limitation remains.

The staged launch driver also cold-loads a real locker for each D-Bus
`Release()` and documented `pkill -USR1 -f '^aerial-lock-supervisor'` route:
it observes `unlock_and_destroy`, supervisor exit 0 without respawn and desktop
input afterwards. `lock-release-shell.qml` adds a real QML lock with a
synthetic in-flight PAM endpoint: release must abort PAM before synchronous
completion, clear pending state, emit `unlocked()` once and destroy the Loader
tree through the normal path. This is the Lock.release() QML regression;
offscreen shims do not substitute for the real session-lock lifecycle.

The same staged driver exercises five-second inactivity locking and a real
visible-surface idle inhibitor: no lock for 15 seconds while inhibited, then
lock within 10 seconds after the probe exits. Each leg uses an independent
owned compositor cycle, observes real lock confirmation, authenticates through
PAM, observes clean exit and checks desktop input afterwards. These nested
checks do not replace real-session service restart, logind or suspend checks
in the disposable guest's own graphical session.

Prepare authentication fixtures only in the disposable guest. Save original
credentials root-only before changing them, pass fixture secrets through stdin,
and restore the original credentials byte-for-byte afterwards. Do not persist
passwords or unfiltered protocol traces in evidence. Capture full screenshots
from the nested compositor into the guest's disk-backed artifact directory.

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
