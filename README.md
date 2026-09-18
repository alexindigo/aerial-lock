# aerial-lock

Wayland session-lock client: PAM authentication over a solid background,
with layered JSON config and i18n. Planned future work is listed under
[Roadmap](#roadmap).

Targets `ext-session-lock-v1`. Developed and tested on Niri; other
compositors are untested — see [Compositor support](#compositor-support).
Not compatible with GNOME.

## Installation

Not yet packaged for any distribution — install from this repo:

```
sudo make install
```

Runtime requirement: [Quickshell](https://github.com/outfoxxed/quickshell)
(any build — not tied to a specific fork).

### Build-time PAM_MAX_RESP_SIZE override

By default, aerial-lock derives `PAM_MAX_RESP_SIZE` from the system PAM headers
at build time. To force a specific value (cross-compilation, hardened distros):

```
make PAM_MAX_RESP_SIZE=1024
```

## Usage

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
qs -p .
```

Before `make install` is run, `/etc/pam.d/aerial-lock` won't exist yet.
Use the env-var override to test with your system's login PAM stack:

```
AERIAL_LOCK_PAM_SERVICE=login qs -p .
```

### Testing

For development testing, enable the debug dismiss button:

1. Edit `~/.config/aerial-lock/config.json`
2. Set `"debugAllowDismiss": true`
3. Launch aerial-lock — a "Dismiss (debug)" button appears that unlocks without authentication
4. **Never enable this on a production system**

## Configuration

On first launch, `~/.config/aerial-lock/config.json` is created with defaults.
See [`docs/config.reference.md`](docs/config.reference.md) for available options.

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
| Hyprland         | Yes       | Untested    |
| Sway >= 1.9      | Yes       | Untested    |
| KDE KWin >= 6.0  | Yes       | Untested    |
| Cosmic           | Yes       | Untested    |
| river / Wayfire  | Probably  | Untested    |
| GNOME / Mutter   | No        | —           |

Recovery from a crashed locker is compositor **policy**, not a protocol
guarantee: `ext-session-lock-v1` says a compositor *may* let a new client
take over a dead lock. Niri does; other compositors still need verifying —
see the per-compositor notes under [Recovery](#recovery-last-resort).

## Recovery (last resort)

The supervisor (`aerial-lock-supervisor`, what `aerial-lock` actually execs)
owns the locker lifecycle: it spawns the QML locker and respawns it up to
three times on abnormal death. When respawns run out it **stays locked** and
escalates loudly — there is **no automatic unlock anywhere**. No path from
the lock screen into the session exists that does not go through PAM.

**Automatic.** If the locker crashes while the session is locked, the
supervisor restarts it (up to 3 times). Exit `0` means clean unlock / PAM
refusal / external invalidation, so it does not respawn; anything else is an
abnormal death and gets a respawn. Compositor death is detected first so the
supervisor never spawns into a dead session. If all respawns fail, it stays
locked — recover manually below.

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

`loginctl unlock-session` does **not** work anywhere — lock state lives in
the compositor, not logind. "Correct password always fails" is a different
symptom (`pam_faillock`); fix with `sudo faillock --reset`.

*Design note:* an earlier automatic takeover-release ("the supervisor unlocks
for you") was shelved to the `shelved/auto-release` branch — it was the only
unauthenticated unlock in the design, so it was cut. If the locker can't
start at all, recovery is manual (this section). A compositor-side minimal
emergency locker (the KDE pattern) is recorded as the future answer for that
strand case.

## Roadmap

Planned, in rough order: video backgrounds (the Apple Aerial use case —
fetch, cache, and rotate videos behind the lock panel), compositor
integrations (idle/suspend/session events), then distribution (AUR
packaging, systemd unit). The detailed phase list lives in the project's
planning documents; nothing shipped today depends on unshipped features.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
