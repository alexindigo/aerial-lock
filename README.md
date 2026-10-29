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

Runtime requirements: [Quickshell](https://github.com/outfoxxed/quickshell)
(any build — not tied to a specific fork),
[qt6-mpvqml ≥ 0.2.0](https://github.com/alexindigo/mpvqml), which plays the video
background, and Qt6's `Qt5Compat.GraphicalEffects` module (`qt6-5compat` on
Arch) for the frosted-clock effect and avatar masking. With an empty
`sources` list the player is never started and the screen stays
`backgroundColor`; with sources it shows `backgroundColor` until the first
frame decodes. The `aerial-lock-fetch` pack downloader (optional) needs
`curl`, `python3`, and `tar`.

### Build-time PAM_MAX_RESP_SIZE override

By default, aerial-lock derives `PAM_MAX_RESP_SIZE` from the system PAM headers
at build time. To force a specific value (cross-compilation, hardened distros):

```
make PAM_MAX_RESP_SIZE=1024
```

## Usage

The installed supervisor launches the shared guarded runner on every attempt,
including solid-background/no-video locks. Its private Qt generic plugin watches
the actual locker Wayland connection independently of GUI/media teardown. A
confirmed transport loss exits abnormally (70); guard monitor failure exits 71
(engagement unknown), while guard startup failure exits 72 before engagement.
None of these paths unlocks. Normal PAM unlock still flushes the unlock request
and exits 0; the supervisor retains its bounded respawn/no-automatic-unlock policy.

Building the native guard/supervisor requires Qt6 Core/Gui/DBus development files,
wayland-client and wayland-protocols. `make install` installs both the shared
runner and private plugin; `PREFIX` and `DESTDIR` select their layout.

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

### Development

Run from the repo during development:

```
make DEBUG_DISMISS=0 DEBUG_VERBOSE=0
bash Scripts/dev/run.sh
```

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
failure — there is **no automatic unlock anywhere**. No path from
the lock screen into the session exists that does not go through PAM.

**Automatic.** If the locker crashes while the session is locked, the
supervisor retries within the three-attempt limit. Locker exit `0` means clean unlock / PAM
refusal / external invalidation, so it does not respawn; anything else is an
abnormal death and gets a respawn. Compositor death is detected first so the
supervisor never spawns into a dead session. If all attempts fail, inspect the
supervisor outcome before assuming that the screen is protected:

| Supervisor exit | Meaning |
|---|---|
| 0 | Clean completion, duplicate supervisor for the same session, or compositor gone. Not a lock-readiness signal. |
| 2 | Other abnormal failures exhausted retries; no automatic unlock. Recover manually below. |
| 3 | Guard unavailable or failed. If every attempt exited 72, the lock never engaged and the screen is **NOT locked**. If a monitor failed (71) or outcomes were mixed, engagement is not confirmed and the screen **may be unlocked**. Inspect the installation and recover from a TTY if needed. |

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

`loginctl unlock-session` does **not** work anywhere — lock state lives in
the compositor, not logind. "Correct password always fails" is a different
symptom (`pam_faillock`); fix with `sudo faillock --reset`.

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

Planned, in rough order: POI overlays / location metadata for the video
background (local sources and Apple/community packs, including fetch and
cache, are implemented), compositor integrations (idle/suspend/session
events), then distribution (AUR packaging, systemd unit). These planned
features are not required by the shipped locker.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
