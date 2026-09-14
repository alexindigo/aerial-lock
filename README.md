# aerial-lock

Wayland session-lock client with Apple Aerial-style video backgrounds.

Targets `ext-session-lock-v1`. Primary compositor: Niri. Also works with
Hyprland, Sway >= 1.9, KDE KWin >= 6.0, Cosmic. Not compatible with GNOME.

## Installation

### Arch Linux (AUR)

```
yay -S aerial-lock
```

### Manual

```
sudo make install
```

Requires [quickshell](https://github.com/outfoxxed/quickshell).

### Build-time PAM_MAX_RESP_SIZE override

By default, aerial-lock derives `PAM_MAX_RESP_SIZE` from the system PAM headers
at build time. To force a specific value (cross-compilation, hardened distros):

```
make PAM_MAX_RESP_SIZE=1024
```

Or when building the AUR package:

```
PAM_MAX_RESP_SIZE=1024 makepkg -si
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

| Compositor       | Status          |
|------------------|-----------------|
| Niri             | Supported       |
| Hyprland         | Supported       |
| Sway >= 1.9      | Supported       |
| KDE KWin >= 6.0  | Supported       |
| Cosmic           | Supported       |
| river / Wayfire  | Likely works    |
| GNOME / Mutter   | Not supported   |

## Recovery (last resort)

The supervisor (`aerial-lock-supervisor`, what `aerial-lock` actually execs)
owns the locker lifecycle: it spawns the QML locker, respawns it up to three
times on abnormal death, then releases the stuck lock in-process. A manual
TTY binary (`aerial-unlock`) is installed alongside for diagnostics.

**Automatic.** You don't need to do anything — if the locker crashes while
the session is locked, the supervisor notices (lock state from the
compositor, not a file), restarts it, and if restarts keep failing it takes
the lock over itself. A respawn that *reached secure and then crashed* is
treated as suspicious and never auto-unlocks (see "Safety gate" below).

**From a TTY (or SSH), as the same user — diagnostics only:**

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

**Safety gate.** The supervisor only auto-releases when every respawn died
*before* reaching secure — the signature of environmental breakage
(compositor/PAM/GL broken), not an attack. If any respawn reached secure and
then crashed, it stays locked and points at manual recovery, because repeated
post-engagement crashes could be attacker-induced from the lock UI.

**Compositor notes.** Dead-locker recovery is compositor policy:

- **Niri / Sway (wlroots)** — takeover of a dead lock is unconditional; the
  tool works as-is. On Niri, a dead locker shows a dark-maroon screen
  (that's the compositor's clientless-lock colour, not aerial-lock).
- **Hyprland ≥ 0.56.1** — a dead locker shows the "lockdead" fallback.
  Recovery needs the client-side flag
  `misc { allow_session_lock_restore = true }`; the supervisor sets it
  just-in-time on a refusal, retries the takeover, then unsets it. (Arch's
  legacy-config-manager build has no `hl.clear_crashed_lockscreen()`, so the
  flag path is the only one that works here.)
- **Hyprland < 0.56.1** — same flag path; no other command exists.
- **GNOME** — the protocol isn't exposed to third-party clients; not
  applicable.

`loginctl unlock-session` does **not** work anywhere — lock state lives in
the compositor, not logind. "Correct password always fails" is a different
symptom (`pam_faillock`); fix with `sudo faillock --reset`.

## License
  applicable.

`loginctl unlock-session` does **not** work anywhere — lock state lives in
the compositor, not logind. "Correct password always fails" is a different
symptom (`pam_faillock`); fix with `sudo faillock --reset`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
