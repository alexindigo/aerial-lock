# Nested-Compositor Testing — aerial-lock

How to test aerial-lock in nested niri and nested Hyprland sandboxes —
safe environments that never risk the host session.

**Iron rule: never launch the sandbox on a live desktop session.** All
testing happens inside a project test-VM fork, created per feature with the
vm-fork fleet procedure: `vm-fork arch-dual-niri aerial-lock <feature>
dual-niri-base`, then fix the fork's video XML to `virtio-vga-gl` + accel3d +
SPICE GL, and if the base image's zero-byte file corruption is still
unrepaired, mass-reinstall packages (`pacman -Qqn | pacman -S --overwrite
"*" -`). Full recipe in `~/Documents/Aerial/reports/d27-execution.md`. Drive
over SSH with `grim`/`wtype`/`ydotool` per the vm-gui-automation skill.

## Prerequisites (inside the test VM)

- niri and Hyprland installed (`pacman -S hyprland` for the latter)
- `ghostty`, `alacritty` or `kitty` (the launcher picks the first present)
- `grim`, `wtype`, `ydotool` for observation and automation
- aerial-lock from this repo at `~/aerial-lock`, with `make install` run
  (installs `/etc/pam.d/aerial-lock`, `/usr/bin/aerial-lock`)
- A dev build when the dismiss button is needed (`make dev` sets
  `DEBUG_DISMISS=1`; release builds cannot show the button)
- A known password for the session user (PAM is real in the sandbox)
- `ydotoold` running as root with a world-readable socket:
  `sudo systemd-run --unit=ydotoold /usr/bin/ydotoold --socket-path=/run/ydotoold.sock --socket-perm=0666`

## Launch

Build the guard first (`make DEBUG_DISMISS=0 DEBUG_VERBOSE=0`); the nested
templates launch `Scripts/dev/run.sh`, which calls the same guarded runner as
the installed supervisor. Bare `qs` is not an authorized production-shell launch.

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
config); the panel (password field + status label) appears centered; on a
dev build the red "Dismiss (debug)" button is visible.

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
killed, but the secure session stays locked: `ext-session-lock-v1` forbids a
compositor from unlocking when its locker dies (niri keeps a solid colour).
That is the expected result, not a failure. A development launch has no
supervisor to start a replacement, so recover by closing the nested sandbox
compositor (T5).

### T5: close the nested window
Close the nested window from the host session. All sandbox state is
destroyed; the host session is unaffected.

## Nested video / VirGL limit

Video backgrounds (`video` / `videoDir`) must **not** be tested on the
nested VirGL GPU (`virtio-vga-gl`): mpv/libplacebo's GL path leaks ~1
`sync_file` fd per frame there and hits the 1024 fd limit in ~35–40 s. The
frame freezes and keyboard input dies (the seat's keymap fd can't be
received), so the lock stops responding to password unlock. Non-video
nested tests are unaffected.

For nested video tests, run the locker with `LIBGL_ALWAYS_SOFTWARE=1`
(llvmpipe — a test-substrate workaround, not a product requirement), or use
real hardware. Details: `~/Documents/Aerial/reports/d33-soak-blocked.md` and
`~/Documents/Aerial/reports/d34-execution.md`.

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
