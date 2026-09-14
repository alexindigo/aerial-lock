# Nested-Compositor Testing — aerial-lock

How to test aerial-lock in nested niri and nested Hyprland sandboxes —
safe environments that never risk the host session.

**Iron rule: never launch the sandbox on a live desktop session.** All
testing happens inside the project's test-VM fork
(`arch-niri-aerial-lock-nested-testing`, forked from `arch-niri`'s
`niri-gui` snapshot per the vm-fork fleet procedure), driven over SSH with
`grim`/`wtype`/`ydotool` per the vm-gui-automation skill.

## Prerequisites (inside the test VM)

- niri and Hyprland installed (`pacman -S hyprland` for the latter)
- `ghostty`, `alacritty` or `kitty` (the launcher picks the first present)
- `grim`, `wtype`, `ydotool` for observation and automation
- aerial-lock from this repo at `~/aerial-lock`, with `make install` run
  (installs `/etc/pam.d/aerial-lock`, `/usr/bin/aerial-lock`)
- `~/.config/aerial-lock/config.json` containing `{"debugAllowDismiss": true}`
- A known password for the session user (PAM is real in the sandbox)
- `ydotoold` running as root with a world-readable socket:
  `sudo systemd-run --unit=ydotoold /usr/bin/ydotoold --socket-path=/run/ydotoold.sock --socket-perm=0666`

## Launch

```sh
Scripts/dev/nested.sh niri            # nested niri window
Scripts/dev/nested.sh hyprland --outputs N   # nested Hyprland + N-1 fake outputs
```

The nested compositor runs as an ordinary Wayland client of the session
compositor, with its own Wayland socket. Getting stuck means closing a
window, never a lockout.

**Never add `--session` to the nested niri.** `--session` imports the
nested environment into the host's systemd and D-Bus, clobbering
`WAYLAND_DISPLAY` for newly-launched host apps — it corrupts the host
environment (regression check: `systemctl --user show-environment` must
still show the original `WAYLAND_DISPLAY` after the sandbox exits).

## Binds

| Bind | niri sandbox | Hyprland sandbox |
|---|---|---|
| Launch locker from the repo | `Mod+L` | `SUPER+L` |
| Kill switch — kill the locker (works while locked) | `Mod+Shift+Escape` (`allow-when-locked`; spawn is the only bind class niri allows to fire while locked) | — |
| Quit the nested compositor | `Mod+Shift+Q` (when unlocked) | `SUPER+Shift+Escape` (`bindl` exit, one press) |

`Mod` is **Alt** when niri runs as a nested window (Super on a TTY).
Ultimate backstop: close the nested window from the host session — works
in every state, independent of any bind.

## Test procedure (fresh sandbox per cycle)

### T1: lock engages
Fire the launch bind. All nested outputs turn solid black (default
config); the panel (password field + status label) appears centered; with
`debugAllowDismiss` the red "Dismiss (debug)" button is visible.

### T2: dismiss button
Click "Dismiss (debug)" — the lock should release and the locker exit.
**Known issue (pending m02):** under nested niri, pointer clicks do not
reach the lock surface (keyboard input does). Until m02 resolves it,
verify release paths via T3/T4.

### T3: password unlock
Type the session password into the field, press Enter. Real PAM
authentication works nested (`pam.d/aerial-lock` → `pam_unix` →
`unix_chkpwd`); the lock releases and the locker exits cleanly.

### T4: kill switch
With the lock engaged, fire the kill-switch bind. The locker process is
killed and the compositor releases the lock.

### T5: close the nested window
Close the nested window from the host session. All sandbox state is
destroyed; the host session is unaffected.

## Hyprland multi-output recipe

```sh
Scripts/dev/nested.sh hyprland --outputs 2
SIG=$(hyprctl instances | grep instance | awk '{print $2}' | head -1)
hyprctl -i "$SIG" monitors        # expect WAYLAND-1 + HEADLESS-1
```

The launcher creates fake headless outputs automatically (retrying until
Hyprland accepts commands — the instance socket appears before the
compositor is ready). `SUPER+L` locks; every output gets the lock
surface. Capture an individual output from inside the sandbox session:

```sh
WAYLAND_DISPLAY=<hyprland socket> grim -o HEADLESS-1 /tmp/headless.png
```

Known quirk: the nested Hyprland window can disappear from the host
session shortly after launch (compositor keeps running headlessly). Drive
it via `hyprctl -i "$SIG" dispatch exec "..."` in that case.

## Automation notes (SSH-driven runs)

- `wtype` text entry works everywhere; `wtype` modifier chords do not
  combine — use `ydotool key` with correct evdev codes (Shift=**42**,
  Alt=56, Super=125, Esc=1, Q=16, L=38, E=18) paced ~150 ms apart.
- `pkill -f` patterns appear in your own shell's cmdline — bracket them
  (`aerial[-]lock`) to avoid self-matching.
- Screenshots: `grim` per display; the nested session's own display gives
  the sandbox's actual rendering.
- Focus the nested window (`niri msg action focus-window`) before sending
  chords.
