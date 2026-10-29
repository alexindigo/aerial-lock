# Nested-Compositor Testing — aerial-lock

Test aerial-lock inside nested niri or Hyprland in a **disposable virtual
machine**, with a working outer Wayland desktop and console/SSH access. Take a
snapshot before changing authentication fixtures. The examples below run in
that guest, from a checkout of this repository.

Session locks are real in a nested compositor. Killing the locker does **not**
unlock a secure session. Authenticate normally or close only the nested
compositor you created; the VM's outer desktop is a separate session.

## Prerequisites (inside the test VM)

- niri or Hyprland installed, plus the build/runtime dependencies in the README
- `ghostty`, `alacritty` or `kitty` (the launcher picks the first present)
- `grim` and `wtype` for capture and text entry
- aerial-lock from this repo, with `make install` run in the guest
  (installs `/etc/pam.d/aerial-lock`, `/usr/bin/aerial-lock`)
- A dev build when the dismiss button is needed (`make dev` sets
  `DEBUG_DISMISS=1`; release builds cannot show the button)
- A known password for the session user (PAM is real in the sandbox)
- A disk-backed temporary/evidence directory:

  ```sh
  mkdir -p "$HOME/aerial-test/tmp" "$HOME/aerial-test/artifacts"
  export TMPDIR="$HOME/aerial-test/tmp"
  ```

## Launch

Build the guard first (`make DEBUG_DISMISS=0 DEBUG_VERBOSE=0`); the nested
templates launch `Scripts/dev/run.sh`, which calls the same guarded runner as
the installed supervisor. Bare `qs -p` is refused before engagement (exit 72).

```sh
Scripts/dev/nested.sh niri            # nested niri window
Scripts/dev/nested.sh hyprland --outputs N   # nested Hyprland + N-1 fake outputs
```

The nested compositor runs as an ordinary Wayland client of the session
compositor, with its own Wayland socket. Record its PID and socket before
automation, and direct every capture/input tool at that nested socket.

**Never add `--session` to the nested niri.** `--session` imports the
nested environment into the guest's outer systemd and D-Bus, clobbering
`WAYLAND_DISPLAY` for newly-launched outer-session apps — it corrupts that
environment (regression check: `systemctl --user show-environment` must
still show the original `WAYLAND_DISPLAY` after the sandbox exits).

## Binds

| Bind | niri sandbox | Hyprland sandbox |
|---|---|---|
| Launch locker from the repo | `Mod+L` | `SUPER+L` |
| Crash test — does not unlock | `Mod+Shift+Escape` (`allow-when-locked`; broad process-name match, so isolate other lockers first) | — |
| Quit the nested compositor | `Mod+Shift+Q` (when unlocked) | `SUPER+Shift+Escape` (`bindl` exit, one press) |

`Mod` is **Alt** when niri runs as a nested window (Super on a TTY).
Backstop: close the owned nested compositor from the VM's outer session or
terminate that recorded compositor PID over SSH. Do not terminate the VM's
outer compositor or another sandbox.

## Test procedure (fresh sandbox per cycle)

### T1: lock engages
Fire the launch bind. Every nested output is covered; solid scenery remains
until video is ready. The selected theme appears on one output, with the
built-in panel available while it loads. The compositor-confirmed
`secure=true` diagnostic (with verbose logging enabled) establishes engagement.

### T2: dismiss button
Click "Dismiss (debug)" — the lock should release and the locker exit.
Debug dismiss is build-gated and is not part of release authentication coverage.
Use the password path to verify real authentication.

### T3: password unlock
Type the session password into the field, press Enter. Real PAM
authentication works nested (`pam.d/aerial-lock` → `pam_unix` →
`unix_chkpwd`); the lock releases and the locker exits cleanly.

### T4: connection-loss/crash behavior
Closing the owned nested compositor makes the guard exit 70 independently of
GUI/media teardown. A locker crash while the compositor is still alive leaves
the session locked; the installed supervisor retries within three total
attempts. It never automatically unlocks. Guard startup refusal is 72; a
running monitor failure is 71. See README recovery for supervisor exit 3 and
its distinction between never engaged and uncertain engagement.

### T5: close the nested window
Close the recorded nested compositor from the VM's outer session. Confirm the
locker exited and outer desktop input still works. A surviving locker is a
failed observation: retain its logs and inspect it rather than killing it.

## Nested video / VirGL limit

Video backgrounds (`sources`) are unreliable on the
nested VirGL GPU (`virtio-vga-gl`): mpv/libplacebo's GL path leaks ~1
`sync_file` fd per frame there and hits the 1024 fd limit in ~35–40 s. The
frame freezes and keyboard input dies (the seat's keymap fd can't be
received), so the lock stops responding to password unlock. Non-video
nested tests are unaffected.

For nested video tests in the VM, set `LIBGL_ALWAYS_SOFTWARE=1` and
`QSG_RHI_BACKEND=opengl` (llvmpipe — a test-substrate workaround, not a product
requirement). Do not set `QT_QUICK_BACKEND=software`: the video item requires
an OpenGL scene graph.

## Hyprland multi-output recipe

```sh
Scripts/dev/nested.sh hyprland --outputs 2
# In another guest terminal, select the instance belonging to this sandbox:
hyprctl instances -j
SIG='recorded-instance-signature'
hyprctl -i "$SIG" monitors        # SIG is that recorded instance signature
```

The launcher creates fake headless outputs automatically (retrying until
Hyprland accepts commands — the instance socket appears before the
compositor is ready). `SUPER+L` locks; every output gets the lock
surface. Capture an individual output from inside the sandbox session:

```sh
WAYLAND_DISPLAY="$NESTED_WAYLAND_DISPLAY" grim -o HEADLESS-1 "$HOME/aerial-test/artifacts/headless.png"
```

Known quirk: the nested Hyprland window can disappear from the outer
session shortly after launch (compositor keeps running headlessly). Drive
it via `hyprctl -i "$SIG" dispatch exec "..."` in that case.

## Automation notes (SSH-driven runs)

- `wtype` text injection is not proof of compositor keybinds or platform IME
  composition. Use the VM's emulated keyboard for a native keybind test.
- Nested Wayland-backed Hyprland has synthetic-input limitations. The automated
  multi-output lane uses render-backed virtual outputs and compositor IPC for
  its launch path. Do not report that as physical-output or native-key coverage.
- Stock Fcitx candidate popups on visible-echo PAM prompts are a known product
  limitation; see the README. Synthetic Qt IME events do not prove that path.
- Screenshots: `grim` per display; the nested session's own display gives
  the sandbox's actual rendering.
- Focus the nested window (`niri msg action focus-window`) before sending
  chords.

The portable suites, integration-driver workspace/manifest format, BLOCKED
retention behavior and credential-handling requirements are documented in
[`Tests/README.md`](../Tests/README.md). Keep fixture passwords out of argv,
environment and logs; restore the guest's original credentials after testing.
