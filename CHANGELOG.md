# Changelog

Notable user-facing changes are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0-alpha.1] — 2026-10-29

First public alpha, covering the project's development from September through
October 2026. This is a standalone Wayland locker; idle/suspend integration,
systemd units and distribution packages are future work.

### Added

Aerial brings local Aerial-style video and full-surface themes to a real
Wayland session lock. Authentication remains independent of scenery and theme
availability, with manual recovery available from another terminal.

- `ext-session-lock-v1` locking with PAM authentication, multi-prompt
  conversations, visible/hidden response modes and a hung-attempt watchdog.
  (`2e48582`, `841c2e6`)
- A supervisor with bounded retries, compositor-death detection and one
  supervisor per protected Wayland session; `aerial-unlock` provides explicit
  last-resort takeover/release from a TTY. (`4fa3a25`, `1d2e0b6`, `1fd4a8d`)
- Looping backgrounds from local files/folders and downloaded Apple/community
  packs. The opt-in `aerial-lock-fetch` command supports resumable downloads,
  resolution bands and a preferred resolution; the locker plays completed local
  clips rather than downloading them. (`c42b08c`, `7f843a9`, `3699942`, `cbccbfc`)
- Five bundled themes: Macintosh, Windows7, MaterialYou, Enfield and Clockwork,
  plus user theme overrides and a built-in fallback panel. A shared editor
  preserves the response and selection through late theme promotion; themes
  can prefer video topics and follow a sampled video accent. (`5bbd3ba`,
  `979f8fe`, `1e8cece`)
- Layered JSON configuration with per-field validation, translated labels and
  focused-output integration for Niri and Hyprland, with a portable output
  fallback. (`d70f6db`, `5314d2d`, `d55f65e`, `edac818`)
- QML, native-input, theme-layout and script regressions, plus isolated
  real-session integration drivers for authentication, connection loss,
  output failover and media resources. (`5bbd3ba`, `979f8fe`, `9ee58cf`)

### Changed

The release uses the current source-list and guarded-launch contracts. Older
development configurations migrate automatically, while installed and
development launches share the same connection protection.

- `sources[]` replaces the legacy `video`, `videoDir` and `apple` configuration
  keys. Existing configurations migrate once; see the configuration reference
  for retaining an older Apple cache. (`3699942`)
- Both the installed supervisor and `Scripts/dev/run.sh` use the guarded runner.
  Bare `qs -p` production-shell launches are refused before engagement.
  Confirmed connection loss exits 70, running-monitor failure 71 and
  pre-engagement guard failure 72. Exhausted guard failures give supervisor
  exit 3 with an explicit never-engaged or uncertain-engagement report.
  (`de1957b`, `74511ed`)

### Fixed

Lifecycle hardening keeps failures in video, themes and outputs from disrupting
authentication. Resource work is bounded at its owner, and incremental builds
now follow their effective install paths and flags.

- Missing/empty PAM service files are detected before locking; an empty initial
  submission shows the requested prompt without overwriting it as busy. Normal
  unlock exits deterministically after releasing the lock. (`97cd411`,
  `c1709b3`, `f681097`)
- Failed video initialization/rendering leaves solid scenery and usable
  authentication. Output removal moves the same editor to a surviving surface;
  a zero-output interval parks it without losing the draft or restarting PAM.
  (`23d9307`, `b08b61d`)
- Accent sampling owns one completion-driven transaction, bounds image decode,
  unloads captured URLs, uses private reused runtime files and samples only the
  consumed background. Late video settles before sampling and does not
  repeatedly resample a completed track. (`c77d172`, `37ea15e`)
- Fallback settlement releases the failed theme candidate; hidden custom carets
  stop animating. Local avatars decode at displayed size × output scale.
  (`fea1c10`, `b46799c`)
- Theme prompts remain visible while typing, narrow layouts fit the surface,
  unavailable actions have accessible names, and MaterialYou's clock lane stays
  layout-owned and independent of date/time text width. (`8949997`, `ea5c9a2`,
  `7db8e4f`, `da5e45c`)
- Native builds keep objects inside the build tree, honor standard compiler/linker
  flags and rebuild when install paths or native configuration change.
  (`e0c16d7`, `a8a2f56`)

### Security

Release authentication has no automatic recovery-unlock path. External text and
command operands are handled as data at their display and tool boundaries.

- Debug dismiss is build-gated and cannot be enabled by user configuration;
  password lengths are not logged, and input respects the compiled PAM response
  limit. Rate limiting is delegated to the system PAM stack. (`4f3e269`,
  `d21c101`, `daf6855`, `1d67873`)
- The connection guard monitors transport loss independently of the GUI/media
  threads. Supervisor retries never perform an automatic takeover-and-unlock.
  (`de1957b`, `1d2e0b6`)
- PAM messages, session labels and other runtime text render literally across
  all themes and the fallback, including reusable text components.
  (`d299904`)
- Linter roots cannot become `find` expressions; external URLs cannot become
  curl options, and nested output counts cannot become arithmetic expressions.
  (`7349676`)

### Requirements and known limitations

Requires Quickshell, **qt6-mpvqml ≥ 0.2.0**, Qt6's `Qt5Compat.GraphicalEffects`
module and a compositor exposing `ext-session-lock-v1`. Building the native
tools/plugin also requires Qt6 Core/Gui/DBus development files and Wayland
client/protocol development files. GNOME and KDE Plasma are not supported.

Stock Fcitx candidate popups on visible-echo PAM prompts can disconnect the
locker; use the plain keyboard input method for those prompts and leave
password input methods disabled. Continuous video track changes have shown
post-warm-up RSS growth of approximately **19 MB/hour**; attribution is open.
Nested Wayland-backed Hyprland also has synthetic-input limitations, so virtual
output results do not imply physical-display or real platform-IME coverage.

PAM account-management flows (such as expired-password changes) are not
implemented. Editable responses remain QML strings on the JS heap and cannot
be reliably zeroed. See [README](README.md#known-limitations) and the
[configuration reference](docs/config.reference.md#known-limitations) for
details and recovery guidance.
