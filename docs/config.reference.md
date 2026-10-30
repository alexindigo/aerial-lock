# aerial-lock Configuration Reference

`~/.config/aerial-lock/config.json` is created automatically on first launch
with defaults.

Bundled defaults are at `/usr/share/aerial-lock/Config/defaults.json`.
User override at `~/.config/aerial-lock/config.json`.

Each field follows strict JSON types (numbers are numbers, strings are strings,
objects are objects), validated **per field**: a field with the wrong type
falls back to its own bundle default with a startup warning naming the full
path (e.g. `panel.widthMax`) — the rest of your config is unaffected.
Unknown fields are ignored. If the file itself is unparseable, the bundle
defaults are used in full.

Your config is deep-merged onto the bundle defaults: a partial `panel` or
`colors` object overrides only the fields it names, and omitted sibling
fields keep their defaults.

## Fields

### Top-level

| Field              | Type    | Default          | Description                                    |
|--------------------|---------|------------------|------------------------------------------------|
| `language`         | string  | `"en"`           | I18n language (`en.json`, future `ru.json`)    |
| `backgroundColor`  | string  | `"#000000"`      | Solid color when no video. CSS hex.            |
| `theme`            | string  | `"Macintosh.qml"`| Whole-surface theme filename (see below).      |
| `sources`          | array   | `[]`             | Video sources, played in list order (see below). Requires qt6-mpvqml ≥ 0.2.0. |
| `preferredResolution` | number | *(absent)*    | `1080` or `2160`. Optional and **not** in the bundle defaults — absence is the signal. See "Resolution" below. |
| `pamService`       | string  | `"aerial-lock"`  | PAM config under `/etc/pam.d/`                 |
| `fallbackQuitMs`   | number  | `3000`           | Retry the explicit quit after unlock if the first deferred quit does not complete. |
| `pamWatchdogTimeoutMs` | number | `60000`       | Abort a PAM call that shows no activity for this interval; keep the lock engaged and allow a fresh attempt. Time spent waiting for the user at a prompt never counts. |

### `sources` (array)

One list of video sources, played in order as a single looping playlist
behind the panel:

```json
"sources": [
  { "type": "file",      "name": "One clip",       "source": "~/Videos/blue.mp4" },
  { "type": "folder",    "name": "Personal",       "source": "~/Videos/locker" },
  { "type": "apple",     "name": "Apple TV",       "source": "https://sylvan.apple.com/Aerials/resources-16.tar" },
  { "type": "community", "name": "Community 2026", "source": "https://aerialscreensaver.github.io/community-2026" }
]
```

Each entry needs `type`, `name`, and `source` (all strings). `type` is one
of `file`, `folder`, `apple`, `community`. A malformed or unknown entry is
dropped with a startup warning naming its index (`sources[2].type`); the
rest of the list is kept. `~` and `$HOME` expand in `file`/`folder` paths.
Remote sources (`apple`/`community`) may also carry `minResolution` /
`maxResolution` (`1080` or `2160`) — the hard band fetch stays within (see
"Resolution"). An invalid band value drops the source with a warning.

- `file` / `folder` — local; played directly. Missing paths are skipped by
  mpv (error logged, playlist moves on), never a crash.
- `apple` / `community` — remote packs. The locker never downloads; it plays
  the pack's cache only when `aerial-lock-fetch` has fetched it (the
  `entries.json` sentinel exists), else the entry is silently skipped.

The cache directory for a remote source is
`$XDG_CACHE_HOME/aerial-lock/<name>/` (else `~/.cache/...`), with the name
sanitized: spaces become `-`, anything outside `[A-Za-z0-9._-]` is stripped.
Two sources sanitizing to the same name → the later one is dropped with a
warning.

**Migration from legacy configs:** on first launch with an old config that
has `video`, `videoDir`, or `apple` but no `sources`, those keys are
rewritten into `sources` entries (`video` → `file`, `videoDir` → `folder`,
`apple.enabled: true` → the Apple pack) and removed from your
`config.json`. The legacy Apple cache lived at `…/aerial-lock/apple/`; the
migrated Apple source caches at `…/aerial-lock/Apple-TV/` — rename the old
directory if you want to keep the already-downloaded clips.

### `panel` (object)

| Field         | Type   | Default | Description                     |
|---------------|--------|---------|---------------------------------|
| `widthMax`    | number | `360`   | Max panel width in px           |
| `fieldHeight` | number | `40`    | Password field height in px     |
| `radius`      | number | `12`    | Panel corner radius in px       |
| `fieldRadius` | number | `8`     | Field corner radius in px       |
| `outerMargin` | number | `20`    | Content margin inside panel     |
| `spacing`     | number | `12`    | Space between panel elements    |
| `fontSize`    | number | `16`    | Text pixel size                 |

### `colors` (object)

| Field                 | Type   | Default        | Description                |
|-----------------------|--------|----------------|----------------------------|
| `text`                | string | `"#dddddd"`    | Normal text color          |
| `textError`           | string | `"#ff5555"`    | Error text color           |
| `input`               | string | `"#ffffff"`    | Input text color           |
| `panelFill`           | string | `"#14ffffff"`  | Panel background (with alpha) |
| `panelBorder`         | string | `"#1fffffff"`  | Panel border (with alpha)  |
| `fieldFill`           | string | `"#0fffffff"`  | Field background (with alpha) |
| `fieldBorderFocused`  | string | `"#40ffffff"`  | Field border when focused  |
| `fieldBorder`         | string | `"#1affffff"`  | Field border (unfocused)   |

## I18n

`Config/i18n/en.json` ships with English strings. Set `"language"` to load a
different bundled file (`Config/i18n/<lang>.json`). Falls back to `en` if the
requested file is missing or unparseable.

User-supplied translation files are **not yet supported** — only the
installed bundle is read.

## Fetching remote sources

`aerial-lock-fetch` (opt-in, run manually) downloads every `apple` /
`community` entry of your `sources` list:

```
aerial-lock-fetch [--limit N]
```

`--limit N` fetches only the first N assets **per source** (good for a
first run). Existing clips are skipped; partial downloads resume. Requires
`curl`, `python3`, and `tar`.

The locker itself never touches the network. An empty `sources` list (the
default) is the solid `backgroundColor`.

### Theme

`theme` names the whole-surface lock UI. The default is `Macintosh.qml`.
The value is a plain QML **filename** (no path, no URL, no traversal) —
anything else is a config bug, warned about and replaced by the built-in
panel. Lookup order: `~/.config/aerial-lock/themes/<name>` first, then the
bundle's `/usr/share/aerial-lock/Themes/<name>`; user files win. The file
is read once per lock — editing it mid-lock never reloads away a partial
response.

Bundled: `Macintosh.qml`, `Windows7.qml`, `MaterialYou.qml`, `Enfield.qml`,
`Clockwork.qml`. See `docs/theming.md` for the authoring contract, the
context object, and the topic-preference semantics that let a theme bias
which of your configured clips play (Enfield prefers mountains).

Only clips that fully downloaded play: a remote clip needs its `.mp4`
present and non-empty plus its sibling `.mp4.done` marker — a partial or
interrupted download is skipped, never played.

### Resolution

Fetch picks one URL per asset from a **hard band** and a **soft
preference**:

- The band is the source's optional `minResolution`/`maxResolution`
  (`1080` or `2160`). Nothing outside it is downloaded — a 4K-only pack
  with `maxResolution: 1080` contributes nothing (warned and skipped).
  Omitted `min` means 0; omitted `max` means no ceiling.
- `preferredResolution` (`1080` or `2160`, global) picks inside the band:
  the same height when available, else the next height **up** — never past
  `maxResolution`. A 4K-only pack with preference 1080 downloads its 4K
  clips.

`preferredResolution` is **existence-written, never overwritten**: when the
key is absent from your `config.json` and outputs are visible (the locker
on start, or fetch under niri/Hyprland), it is stamped from the largest
connected output's logical height (`>= 2160` → 2160, else 1080). A key
already in the file is never touched — even an invalid one (an out-of-band
value is ignored with a warning, and left in the file). If the key is
absent and no outputs are visible, that run picks the highest in-band URL
and writes nothing.

## Known limitations

- Stock Fcitx candidate popups on visible-echo PAM prompts can disconnect the
  locker; keep password input methods disabled and use the plain keyboard
  method for those prompts. Long video locks have shown approximately 19 MB/h
  RSS growth under continuous track changes. Nested Hyprland synthetic input
  also has coverage limits. See [README known limitations](../README.md#known-limitations)
  for symptoms and workarounds.
- **No PAM account-management phase.** Quickshell's `PamContext` runs
  `pam_authenticate` only, so interactive account-management flows (e.g. an
  expired password's "new password/retype" prompt) are unreachable — identical
  to swaylock and hyprlock, which are also auth-only. A plain expired password
  still authenticates correctly.
- **Plaintext password lifetime.** The response being edited is held as a
  QML string in the shared input state (`context.auth.input`): it lives on
  the JS heap for the whole editing session, cannot be zeroed, and a
  cleared value survives until garbage collection. On accepted submission
  the draft is consumed and cleared (all field mirrors follow), and an
  accepted response queued for PAM's first prompt is cleared *before*
  `respond()` is called, on failure, abort and teardown. A native undo
  cannot resurrect consumed text (the authoritative clear is programmatic,
  which resets the field's undo history). The exposure is narrowed, not
  eliminated; a real fix needs an `mlock`ed buffer behind a C++ helper.

## Recovery

The supervisor (`aerial-lock-supervisor`, what `aerial-lock` execs) owns the
locker lifecycle: spawns the QML locker, respawns on abnormal death (limit
**3 total attempts**, short backoff). There is no automatic unlock. Locker exit
`0` means clean unlock / PAM refusal / external invalidation; abnormal exits
retry. Guard startup failure is `72` (that attempt never engaged); monitor
failure is `71` (engagement unknown). At exhaustion the supervisor exits `3`
for guard failures: all-72 attempts mean the screen is **NOT locked**, while
mixed outcomes or a monitor failure mean it **may be unlocked**. Other abnormal
failures exit `2`. Manual recovery is `aerial-unlock`
from a TTY (see the README's "Recovery (last resort)" section for exit codes
and the per-compositor story). Behaviour is fixed — the respawn limit and
timeouts are build constants, not configuration.

## Rate limiting and lockout

Throttling is delegated to the PAM stack. `aerial-lock` adds no client-side
attempt counter: on `PamResult.MaxTries` the UI shows a message but leaves
the field enabled, and a fresh attempt starts a **new** PAM transaction with
a reset counter — retries are effectively unlimited from the client's
perspective.

This is deliberate, and matches swaylock and hyprlock. A client-side counter
is bypassed by restarting the locker, so it buys no security against anyone
who can spawn a process — and a lockout counter in the locker is a new way
to fail closed: a bug in it locks out the legitimate user permanently.
Cost with no benefit.

The shipped `/etc/pam.d/aerial-lock` is `auth include login`, so whatever
policy the system login stack enforces applies here automatically — which is
what makes delegation sound rather than lazy. Hardening belongs in
`/etc/pam.d/login` via `pam_faildelay` or `pam_faillock`, not in the locker.

## PAM_MAX_RESP_SIZE

This value is derived at build time from `/usr/include/security/_pam_types.h`
(`gen-pam-limits.c`). It is NOT configurable at runtime — it reflects the
actual limit of the PAM library compiled on your system.

To force a specific value at build time:
```
make PAM_MAX_RESP_SIZE=1024
```

The value is logged on every startup. If it differs from your expectation,
rebuild the package.

## Compositor

Not user configuration. At lock time, aerial-lock reads the focused output
from a compositor backend if one is present:

- `NIRI_SOCKET` set → niri (`NiriState.activeOutput`)
- `HYPRLAND_INSTANCE_SIGNATURE` set → Hyprland (`Hyprland.focusedMonitor.name`)
- otherwise, or if the backend fails to load, or if the name has no usable
  lock surface → the first usable lock surface, with a warning in the last case

There is no config key to pick a screen. A wrong name must not hide the
panel. The selected surface stays pinned until it disappears; the same
theme/editor then moves to a survivor, preserving the draft, selection and PAM
state. With no usable lock surface it waits and recovers when a surface returns.
Hyprland's real `FALLBACK` output is usable; Qt's placeholder screen is not a
lock surface by itself.

## Debug / development

Debug behaviour is a **build-time** property, not user configuration: `make`
writes `Config/build-flags.json` (root-owned when installed) with
`debugAllowDismiss` and `verbose`, both `false` in release builds.
`make dev` sets both `true` — the dismiss button bypasses authentication, so a
dev build prints a startup warning. A user config cannot enable either flag.

### Environment overrides

| Variable                    | Overrides      | Purpose                        |
|-----------------------------|----------------|--------------------------------|
| `AERIAL_LOCK_PAM_SERVICE`   | `pamService`   | Dev testing without installing PAM file |

Example:
```
AERIAL_LOCK_PAM_SERVICE=login bash Scripts/dev/run.sh
```

## Example

```json
{
  "language": "en",
  "backgroundColor": "#1a1a2e",
  "sources": [
    { "type": "apple", "name": "Apple TV", "source": "https://sylvan.apple.com/Aerials/resources-16.tar" }
  ],
  "pamService": "login",
  "fallbackQuitMs": 3000,
  "panel": {
    "widthMax": 400,
    "fieldHeight": 44,
    "radius": 14,
    "fieldRadius": 10,
    "outerMargin": 20,
    "spacing": 12,
    "fontSize": 16
  },
  "colors": {
    "text": "#eeeeee",
    "textError": "#ff6666",
    "input": "#ffffff",
    "panelFill": "#14ffffff",
    "panelBorder": "#1fffffff",
    "fieldFill": "#0fffffff",
    "fieldBorderFocused": "#40ffffff",
    "fieldBorder": "#1affffff"
  }
}
```

Additional fields will be added in future phases for overlays
and idle behavior.
