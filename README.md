# aerial-lock

Wayland session-lock client: PAM authentication over a looping video
background (local files or Apple/community packs) with a solid colour
until the first frame, layered JSON config and i18n. Planned future work
is listed under [Roadmap](#roadmap).

Targets `ext-session-lock-v1`. Tested on Niri and Hyprland — see
[Compositor support](#compositor-support) for coverage and limitations.
Not compatible with GNOME or KDE Plasma (their compositors do not expose
`ext-session-lock-v1` to third-party lockers).

## Installation

Not yet packaged for any distribution — install from this repo:

```
sudo make install
```

Runtime requirements: [Quickshell 0.3.x](https://github.com/outfoxxed/quickshell)
(not tied to a specific fork),
[qt6-mpvqml ≥ 0.2.0](https://github.com/alexindigo/mpvqml), which plays the video
background, and Qt6's `Qt5Compat.GraphicalEffects` module (`qt6-5compat` on
Arch) for the frosted-clock effect and avatar masking, Qt6 Core/Gui/DBus
(`qt6-base`), PAM and `wayland`. The guarded runner also requires Bash;
the optional signal-unlock examples below use `pkill` (`procps-ng` on Arch).
With an empty
`sources` list the player is never started and the screen stays
`backgroundColor`; with sources it shows `backgroundColor` until the first
frame decodes. The `aerial-lock-fetch` pack downloader (optional) needs
`curl`, `python3`, and `tar`.

Building requires a C/C++ compiler, Make, pkg-config, Qt6 Core/Gui/DBus/Quick
development files, PAM headers, wayland-client and wayland-protocols (including
`wayland-scanner`). On Arch these are provided by `base-devel`, `qt6-base`,
`qt6-declarative`, `pam`, `wayland` and `wayland-protocols`; Git is needed to build from a clone.

With the default `PREFIX=/usr`, installation includes `aerial-lock`,
`aerial-lock-supervisor`, `aerial-unlock`, `aerial-lock-fetch` and `aerial-idle`
in `/usr/bin`, the shared guarded runner under `/usr/libexec/aerial-lock`, its
private plugin under `/usr/lib/aerial-lock/qt-plugins`, the QML/config/theme
bundle under `/usr/share/aerial-lock`, and `/etc/pam.d/aerial-lock`. It also
installs `/usr/lib/systemd/user/aerial-idle.service` and
`/usr/share/aerial-lock/examples/idle.json`. The service is **not enabled
automatically**. `PREFIX` and `DESTDIR` select the install layout.

### Build-time PAM_MAX_RESP_SIZE override

By default, aerial-lock derives `PAM_MAX_RESP_SIZE` from the system PAM headers
at build time. To force a specific value (cross-compilation, hardened distros):

```
make PAM_MAX_RESP_SIZE=1024
```

## Usage

Type and submit on any locked output; all surfaces share one draft and the panel stays pinned to its selected output.

The installed supervisor launches the shared guarded runner on every attempt,
including solid-background/no-video locks. Its private Qt generic plugin watches
the actual locker Wayland connection independently of GUI/media teardown. A
confirmed transport loss exits abnormally (70); guard monitor failure exits 71
(engagement unknown), while guard startup failure exits 72 before engagement.
None of these paths unlocks. Normal PAM unlock still flushes the unlock request
and exits 0; the supervisor retains its bounded respawn/no-automatic-unlock policy.

Bind a key in your compositor config:

**Niri**
```kdl
binds {
    Mod+L allow-when-locked=true { spawn "aerial-lock"; }
}
```

**Hyprland**
```conf
bind = SUPER, L, exec, aerial-lock
```

One supervisor protects each Wayland session. Running `aerial-lock` again for
a session that is already being locked (a keybinding and an idle daemon, say)
starts no second locker: the new invocation asks the supervisor on duty for its
actual lock state and exits 0 only once that supervisor's current locker has
reported the compositor's lock confirmation. It waits up to 10 seconds while
the lock is still being engaged and otherwise exits 4 (see
[Recovery](#recovery-last-resort)).

### Idle, suspend and session integration

`aerial-idle` is the companion idle/session daemon. It locks on configured
inactivity, before logind-managed suspend/hibernate (including lid-close sleep),
and on `loginctl lock-session`; it forwards `loginctl unlock-session` to the
supervisor. Enable it from your graphical session:

```sh
systemctl --user enable --now aerial-idle.service
```

The user manager must have the session's `WAYLAND_DISPLAY` and
`XDG_RUNTIME_DIR` environment (and compositor IPC variables for focused-output
selection). The unit belongs to `graphical-session.target` and requires
`WAYLAND_DISPLAY`. With no user config, suspend and logind lock/unlock handling
are **on**, but there is **no idle timeout**:

| Key | Default | Meaning |
|---|---|---|
| `idle.timeoutSeconds` | `0` | Nonnegative integer seconds; `0` disables inactivity locking. |
| `idle.respectInhibitors` | `true` | Wayland idle inhibitors postpone the inactivity timeout. |
| `idle.lockOnSuspend` | `true` | Hold a sleep-delay inhibitor until lock confirmation, bounded by logind's delay limit minus 500 ms. |
| `idle.logindLockUnlock` | `true` | Forward logind `Lock` and `Unlock` events for the graphical session. |

For a five-minute timeout, copy the installed example **if you have no config
yet**:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/aerial-lock"
cp -n /usr/share/aerial-lock/examples/idle.json "${XDG_CONFIG_HOME:-$HOME/.config}/aerial-lock/config.json"
```

If a config already exists, merge the example's `idle` object into it instead
of replacing the file. The example is never read automatically. The daemon
reads the same layered config once at startup, without rewriting it; apply
edits with `systemctl --user restart aerial-idle.service`. Inspect the effective
idle settings with `aerial-idle --print-config`. See the
[configuration reference](docs/config.reference.md#idle-object) for validation
and protocol fallback behavior.

Each lock runs independently: in its own transient user unit when the systemd
user manager is reachable, otherwise as a detached process. Restarting or
stopping aerial-idle leaves a running lock intact. Locks started by keybinds or
other callers are discovered through the same session-scoped supervisor;
aerial-idle does not need to have started them.

### Alternatives without aerial-idle

Use one idle/session policy owner. With swayidle or hypridle handling these
events, leave aerial-idle disabled. A shell can set its `lockCommand` to
`aerial-lock`; turn off the shell's own lock-on-suspend when aerial-idle owns
that policy, to avoid competing lockers.

For **swayidle** built with logind support:

```sh
swayidle -w \
    timeout 300 'aerial-lock' \
    before-sleep 'aerial-lock' \
    lock 'aerial-lock' \
    unlock "pkill -USR1 -f '^aerial-lock-supervisor'"
```

`aerial-lock` stays in the foreground for the lock's lifetime, so swayidle's
`-w` before-sleep command waits until unlock or logind's maximum delay expires;
it is not a lock-readiness-only wait. aerial-idle instead releases its delay
as soon as the supervisor confirms the lock.

For **hypridle**:

```conf
general {
    lock_cmd = aerial-lock
    unlock_cmd = pkill -USR1 -f '^aerial-lock-supervisor'
    before_sleep_cmd = loginctl lock-session
}

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}
```

Both examples wire logind's unlock event explicitly. `pkill -f` matches the
command line: `pkill -x aerial-lock-supervisor` cannot match the kernel's
15-character process-name limit. The expression above targets supervisors
for all this user's Wayland sessions; the session-scoped D-Bus `Release()`
method can target one session (see [Recovery](#recovery-last-resort)).

### Systemd-less sessions

Start `aerial-idle` from compositor autostart or your user service manager
with the Wayland/session-bus environment. For example, Niri accepts:

```kdl
spawn-at-startup "aerial-idle"
```

Without a systemd user manager, locks use the detached launch path. elogind
exposes the same login1 API for suspend and lock/unlock events, but **a real
elogind setup is unverified**. With no logind/elogind, aerial-idle warns and
only inactivity locking is available; use your distribution's sleep hooks to
run `aerial-lock` in the graphical user's session before sleep. Those hooks
must supply that session's environment and coordinate sleep with confirmed
locking; a root hook with no Wayland/session-bus environment is insufficient.

### Development

Enable the pre-commit hook with `git config core.hooksPath .githooks`; it needs
Podman and a user systemd session, and builds a resource-limited Arch lint image
automatically when `.devcontainer/` changes. GitHub CI builds the same container
and runs the same QML lint offline with the repository mounted read-only;
the hook additionally checks staged whitespace.

Run from the repo during development:

```
make DEBUG_DISMISS=0 DEBUG_VERBOSE=0
bash Scripts/dev/run.sh
```

`AERIAL_LOCK_SHELL` selects the shell directory for `aerial-lock` and the bundled
`Config/defaults.json` read by `aerial-idle`. Set it to the source tree for both
processes when testing a development bundle. Unset or empty, it uses the compiled
`DATADIR` (normally `/usr/share/aerial-lock`). Paths are made absolute and cleaned
at startup; a relative override is resolved against the caller's working
directory. A nonempty override is passed as that absolute path to locks started
by aerial-idle, including transient systemd units and detached processes.

Before `make install` is run, `/etc/pam.d/aerial-lock` won't exist yet.
Use the env-var override to test with your system's login PAM stack:

```
AERIAL_LOCK_PAM_SERVICE=login bash Scripts/dev/run.sh
```

### Testing

Use a disposable test VM for builds, automated tests and nested-compositor
experiments. See [`Tests/README.md`](Tests/README.md) for the portable suites and
integration drivers, and [`docs/nested-testing.md`](docs/nested-testing.md) for
the interactive workflow. Inside that VM, a development build can be launched
with the debug flags:

```
make dev
```

`make dev` builds with `DEBUG_DISMISS=1` (a "Dismiss (debug)" button that
unlocks without authentication) and `DEBUG_VERBOSE=1`, then launches from the
repo. Both flags land in the build-generated, root-owned
`Config/build-flags.json` — a dev build prints a startup warning when the
bypass is enabled. Release builds (`make`) always set both flags `false`;
**user configuration cannot enable the bypass.** For a chatty build without
the bypass: `make DEBUG_VERBOSE=1`.

## Configuration

On first launch, `~/.config/aerial-lock/config.json` is created with defaults.
See [`docs/config.reference.md`](docs/config.reference.md) for available options.

### Themes

The lock surface is a full-surface QML theme, selected by filename with the
`theme` key (default `"Macintosh.qml"`). Five ship in the bundle —
Macintosh, Windows7, MaterialYou, Enfield, Clockwork — and you can drop
your own into `~/.config/aerial-lock/themes/` (user files win over
same-named bundled ones). Enfield prefers mountain videos; the other themes
play your configured pool as-is. The authoring contract, the shared
`LockContext` object, and the topic-matching semantics are documented in
[`docs/theming.md`](docs/theming.md).

### Video backgrounds

The `sources` list drives the background — local files and folders plus
Apple Aerial and community packs, played in list order as one looping
playlist:

```json
"sources": [
  { "type": "apple",  "name": "Apple TV", "source": "https://sylvan.apple.com/Aerials/resources-16.tar" },
  { "type": "folder", "name": "Personal", "source": "~/Videos/locker" }
]
```

Remote packs are downloaded by hand — the locker never fetches:

```
aerial-lock-fetch --limit 5     # a first, small run
aerial-lock-fetch               # everything in sources[]
```

Clips cache under `~/.cache/aerial-lock/<name>/`; a pack plays only once
fetched, and an unfetched pack is skipped silently. Clip resolution follows
a per-source `minResolution`/`maxResolution` band plus a global
`preferredResolution`, which is stamped into your config from your largest
display the first time outputs are visible (and never overwritten after
that). See [`docs/config.reference.md`](docs/config.reference.md) for the
full `sources` reference, the resolution rules, and migration from the old
`video`/`videoDir`/`apple` keys.

### Environment overrides

| Variable                    | Overrides      | Purpose                        |
|-----------------------------|----------------|--------------------------------|
| `AERIAL_LOCK_PAM_SERVICE`   | `pamService`   | Dev testing without installing PAM file |
| `AERIAL_LOCK_SHELL` | Shell/bundle directory | Shared by the supervisor and aerial-idle; unset or empty uses compiled `DATADIR` |

## Compositor support

Two separate questions: does the compositor implement
`ext-session-lock-v1`, and has aerial-lock been run on it?

| Compositor       | Protocol  | aerial-lock |
|------------------|-----------|-------------|
| Niri             | Yes       | Tested      |
| Hyprland         | Yes       | Tested      |
| Sway >= 1.9      | Yes       | Untested    |
| Cosmic           | Yes       | Untested    |
| river / Wayfire  | Probably  | Untested    |
| KDE KWin / Plasma| No        | —           |
| GNOME / Mutter   | No        | —           |

The password panel is placed on the compositor's focused output when that
name matches a usable lock surface (`NIRI_SOCKET` → niri,
`HYPRLAND_INSTANCE_SIGNATURE` → hyprland). Otherwise it goes on the first usable
lock surface. The selection stays pinned while that surface exists. If it is
removed, the same theme and editor move to a surviving output without clearing
the typed text or selection and without restarting PAM; if no lock surface is
left, the editor waits until one returns. Hyprland's own `FALLBACK` output is a
real lock surface and receives the editor.

Recovery from a crashed locker is compositor **policy**, not a protocol
guarantee: `ext-session-lock-v1` says a compositor *may* let a new client
take over a dead lock. Niri does; other compositors still need verifying —
see the per-compositor notes under [Recovery](#recovery-last-resort).

## Recovery (last resort)

The supervisor (`aerial-lock-supervisor`, what `aerial-lock` actually execs)
owns the locker lifecycle: it spawns the QML locker and respawns it up to
three total attempts on abnormal death. When attempts run out it reports the
failure — crash recovery never unlocks automatically. Normal interactive
unlock goes through PAM. An explicit D-Bus `Release()` call on
`org.aeriallock.Supervisor` at `/org/aeriallock/Supervisor` (on its
session-scoped `org.aeriallock.Supervisor.s<hash>` bus name), or SIGUSR1 to
the supervisor on duty, releases its locker gracefully without PAM:

```sh
pkill -USR1 -f '^aerial-lock-supervisor'
```

Any caller on the user's session bus may call `Release()`, and any process
running as the user can request this external unlock, as with
swaylock/hyprlock. A release requested while the locker is still engaging is
delivered once it confirms the lock. Release disables further respawns;
the locker takes its normal unlock/teardown path and exits 0.

**Automatic.** If the locker crashes while the session is locked, the
supervisor retries within the three-attempt limit. Locker exit `0` means clean unlock / PAM
refusal / external invalidation, so it does not respawn; anything else is an
abnormal death and gets a respawn unless release was requested. Compositor death is detected first so the
supervisor never spawns into a dead session. If all attempts fail, inspect the
supervisor outcome before assuming that the screen is protected:

| Supervisor exit | Meaning |
|---|---|
| 0 | Clean completion or compositor gone; for the supervisor on duty this is not a lock-readiness signal. A duplicate invocation for a session that is already protected exits 0 only after the supervisor on duty confirmed that its current locker holds the lock. |
| 1 | The supervisor could not start: the session to protect, the session bus or its per-session name is unavailable. Nothing was launched. |
| 2 | Other abnormal failures exhausted retries, or the locker exited abnormally after an explicit release request (without respawn); no automatic recovery unlock. After release the screen state is **unknown**. Otherwise the log says the session stays locked only if an attempt confirmed the lock; without confirmation the current screen state is **unknown**. Recover manually below. |
| 3 | Guard unavailable or failed. If every attempt exited 72, none of this run's attempts engaged a lock, but the current screen state is **unknown**: a lock from an earlier run may still be held. If a monitor failed (71) or outcomes were mixed, engagement is not confirmed and the screen **may be unlocked**. Check the screen, inspect the installation and recover from a TTY if needed. |
| 4 | Duplicate invocation, lock not confirmed: another supervisor is on duty for this session, but it did not report a confirmed lock within 10 seconds (still engaging, failing or gone), or the name's owner gave no valid state. The screen **may be unlocked**; this invocation launched nothing. |

**From a TTY (or SSH), as the same user — manual recovery / diagnostics:**

```
export XDG_RUNTIME_DIR=/run/user/$(id -u)
# find the stuck session's socket — usually the older wayland-N
ls -la $XDG_RUNTIME_DIR/wayland-*
WAYLAND_DISPLAY=wayland-N aerial-unlock
```

Then switch back to that session's TTY. If a *live* locker still holds the
lock, the tool reports the PID and suggests:

```
aerial-unlock --purge    # kill stale aerial-lock processes, then recover
```

| Exit | Meaning |
|---|---|
| 0 | recovered — lock taken over and released |
| 1 | no Wayland socket / environment (guidance printed) |
| 2 | inconclusive — compositor didn't answer within 5 s |
| 3 | refused — a live client holds the lock (PID + `--purge` hint) |

**Compositor notes.** Dead-locker recovery is compositor policy:

- **Niri / Sway (wlroots)** — takeover of a dead lock is unconditional; a
  respawned locker replaces the dead one with no flag. On Niri, a dead locker
  shows a dark-maroon screen (that's the compositor's clientless-lock colour,
  not aerial-lock).
- **Hyprland ≥ 0.56.1** — a dead locker shows the "lockdead" fallback. A
  respawned locker is refused without the client-side flag
  `misc { allow_session_lock_restore = true }`; the supervisor sets it
  just-in-time on Hyprland, respawns, and unsets it when the episode ends.
  (Arch's legacy-config-manager build has no `hl.clear_crashed_lockscreen()`,
  so the flag path is the only one that works here.)
- **Hyprland < 0.56.1** — same flag path; no other command exists.
- **GNOME** — the protocol isn't exposed to third-party clients; not
  applicable.
- **KDE Plasma (KWin)** — KWin does not implement `ext-session-lock-v1`;
  it is its own lock daemon (KScreenLocker in-process) and only offers the
  private `kde-lockscreen-overlay-v1`. Quickshell correctly reports
  "compositor does not support the ext-session-lock-v1 protocol". This is
  a compositor gap, not a Quickshell or aerial-lock one; every third-party
  session-lock client is affected the same way. Not applicable.

`loginctl unlock-session` works through aerial-idle (with
`idle.logindLockUnlock=true`) or an alternative daemon's explicitly wired
unlock event. Without such a listener, use `Release()` or SIGUSR1 directly;
logind does not itself release the compositor lock. "Correct password always
fails" is a different symptom (`pam_faillock`); fix with `sudo faillock --reset`.

If the locker cannot start, fix the installation from a TTY. When a previous
attempt already engaged the lock, manual recovery may also be needed; the
supervisor never performs takeover-and-unlock automatically.

## Known limitations

- **Stock Fcitx visible-echo prompts.** With a CJK engine active, a PAM prompt
  requesting visible input can trigger a candidate popup whose parent is not
  valid for a session-lock surface. The compositor may disconnect the locker;
  the connection guard exits 70 and bounded retries may end with a clientless
  lock requiring TTY recovery. Ordinary hidden-password prompts use Fcitx's
  plain-keyboard path by default. Keep `AllowInputMethodForPassword` disabled
  and switch to the plain keyboard input method for visible-echo prompts.
- **Memory during long video locks.** Continuous track changes have shown
  post-warm-up RSS growth of about **19 MB/hour**. Attribution remains open;
  this alpha does not claim flat memory use over arbitrarily long locks.
- **Nested Hyprland input.** Synthetic keyboard/pointer input into nested
  Wayland-backed Hyprland is not reliable in every setup. The automated
  multi-output lane uses render-backed virtual outputs; this does not establish
  physical-output or real platform-IME coverage. See the nested testing guide.
- **Authentication and secret lifetime.** PAM account-management flows are not
  implemented, and editable response strings live on the QML heap. See the
  [configuration reference](docs/config.reference.md#known-limitations).

## Roadmap

Idle/suspend/session events and the opt-in aerial-idle user unit are
implemented. Distribution packaging is being prepared; no AUR package has
been published yet. Future work includes POI overlays / location metadata
for video backgrounds. Local sources and Apple/community packs, including
fetch and cache, are already implemented.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
