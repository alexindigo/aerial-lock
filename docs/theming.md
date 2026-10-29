# Theming

Aerial's lock surface is a full-surface QML theme. Five ship in the bundle;
users may drop their own into `~/.config/aerial-lock/themes/`.

## Selecting a theme

```json
{ "theme": "Macintosh.qml" }
```

The `theme` config key is a **plain QML filename** — not a path or URL.
Lookup order:

1. `~/.config/aerial-lock/themes/<name>` (or `$XDG_CONFIG_HOME/...`) — user
2. `/usr/share/aerial-lock/Themes/<name>` (the bundle)

A user file with the same name wins over the bundled one. A broken user
override does **not** fall through to the bundled same-name file; the
built-in panel is shown and the log names the path and reason. The setting
is read **once per lock**: no live theme replacement, and editing files
mid-lock can never reload away a partially entered response (the shell's
`watchFiles` is off).

The trusted panel is available immediately. Theme files are probed and
loaded asynchronously only after the compositor confirms lock coverage.
If loading fails or exceeds two seconds, the panel remains for that lock.
When a theme becomes ready while you are already typing into the panel, it
**takes over the shared draft**: the exact text and selection are handed
off to the theme's field (deferred only until an in-progress IME
composition finishes naturally) — a late theme never loses partially
entered input and never restarts PAM.
Hidden candidates must not force focus or perform other global actions.

Bundled themes:

| Theme | Look | Topic preference |
|---|---|---|
| `Macintosh.qml` (default) | Centered date + large frosted clock top; name/field bottom (d45: no avatar), over video | none |
| `Windows7.qml` | Faithful qylock `windows_7` adaptation: centered glass-framed square avatar, field + attached arrow, Switch User and full footer bar | none |
| `MaterialYou.qml` | Faithful qylock `material-you` light-variant composition: stacked clock + date pill, QUICK SETTINGS grid, notification-style auth card. d45: the tonal palette rotates to the video's sensed accent hue (static lavender when unsensed) | none |
| `Enfield.qml` | Faithful qylock `enfield`: Orbitron clock top-left, line-dot divider, standalone password pill with star mask + glowing star caret, footer. d45: the sakura accent tier (divider/caret/submit/petals/atmosphere) follows the video's sensed accent hue | `mountain`, `mountains` |
| `Clockwork.qml` | Faithful qylock `orbital`: two numbered minute/second scales cropped at the left edge, reading pill + hour + date, top-right action strip, right-aligned auth. d45: reference gray tier brightened + text shadows for bright-video contrast (recorded palette deviation) | none |

The four qylock-derived themes adapt `Darkkal44/qylock` @ `f6561e2` (GPLv3;
`material-you`'s metadata separately declares MIT) — see
`Themes/ATTRIBUTION.md` for the full notice. Their system-action controls
(user switching, session selection, restart/shutdown/suspend) are drawn in
their reference positions but **visibly unavailable** (dimmed, with a hover
notice): the backend is a follow-up TODO, not a hidden no-op. The real
authentication submit controls (arrow/UNLOCK/ENTER KEY) work through the
shared input core.

## Writing a theme

A theme is a QML file whose root is a `FocusScope` taking the lock context:

```qml
import QtQuick
import "root:/Services"               // resolves against the running shell
import "root:/Modules/Lock" as LockModule

FocusScope {
    id: root
    required property LockContext context
    property Item backdrop: null      // optional — scenery, see below

    // Optional: playlist topic preference (whole words, OR semantics)
    readonly property var preferredTopics: ["mountain"]

    // Optional: called when the session lock becomes secure — aim the
    // input focus. With AuthField: field.focusField().
    function focusInput() { field.focusField() }

    // The theme owns the field's decoration; AuthField draws nothing.
    Rectangle {
        anchors.centerIn: parent
        width: 280
        height: root.context.panel.fieldHeight
        radius: root.context.panel.fieldRadius
        color: root.context.colors.fieldFill
        border.width: 1
        border.color: field.hasActiveFocus
            ? root.context.colors.fieldBorderFocused
            : root.context.colors.fieldBorder

        LockModule.AuthField {
            id: field
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            context: root.context
        }
    }
}
```

- **`context`** (required) is injected at creation time — available before
  your bindings and `Component.onCompleted` run.
- **`backdrop`** (optional): declare it and the host binds the
  surface-local scenery item (the video background) into it — for
  FrostedText-style sampling. It may be `null` (no video); handle that.
  It is scenery only — there is no player API. It is never the lock
  surface itself (sampling that would be a feedback loop).
- **`preferredTopics`** (optional): an array of strings. Wrong types warn
  and become "no preference". See "Topic preference" below.
- **`focusInput()`** (optional): the host calls it when the lock is fully
  engaged. Without it, the host force-focuses the theme root — fine when
  your field has `focus: true` inside a scope.

Shared building blocks you can import from `root:/Modules/Lock`:

- **`AuthField`** — the password input core (native editing, IME handling,
  masking, PAM echo visibility, response limit, disabled-while-busy, focus
  recovery, initial-space tunings). It is **decoration-free**: no frame,
  fill, border, radius, height or padding — your theme draws those around
  it (a plain `Rectangle` works, see above) and reads `field.hasActiveFocus`
  for focus styling. Character-presentation inputs (all optional, all
  default-preserving): `textColor`, `selectionColor`, `selectedTextColor`,
  `fontPixelSize`, `maskCharacter` (construction-time; empty keeps Qt's
  platform glyph), and (d44) `fontFamily`, `fontWeight`,
  `fontLetterSpacing`, `horizontalAlignment`, `cursorDelegate` (a draw-only
  custom caret; the native editor still positions it). Behavior tunings:
  `initialSpacePolicy`, `initialSpaceScope` (see "Initial-space tunings").
  Public methods: `submit()`, `focusField()`; `hasActiveFocus` for styling.
  A themed submit *button* calls `field.submit()` — the exact path Return
  takes. Never reach into its internal TextInput.
- **`Avatar`** — local `$HOME/.face` when it loads, drawn
  initials/person fallback otherwise. Inputs: `source`, `loginName`,
  `diameter`, `fallbackFill`, `foreground`, and (d44) `cornerRadius` —
  negative (the default) keeps the circle; a value in px rounds the image,
  initials and person fallback identically (used by Windows7's square
  crop).
- **`FrostedText`** — translucent digits: blurred backdrop inside crisp
  glyph silhouettes. Inputs: `scenery` (an Item, e.g. your `backdrop`),
  `text`, `fontPixelSize`, `fontFamily`, `fontBold`, `padding`,
  `blurRadius`, `tintColor`, `fallbackColor`. Null scenery renders plain
  readable text.

## The context contract

All authentication flows through `context.auth` — a theme never touches
PAM, mpv, or the config. All strings are `""` and numbers `0`/`-1` when
unknown.

### `context.auth`

| Property / method | Type | Meaning |
|---|---|---|
| `status` | string | Current status message (prompt, "Authenticating…", failure) |
| `inProgress` | bool | PAM is starting or processing a response; input is disabled. It clears when PAM requests the next response or the attempt ends. |
| `isError` | bool | The last attempt failed / errored |
| `responseVisible` | bool | The active PAM prompt requests visible input. False outside a live response request, including retries after failure or timeout. |
| `maxResponseSize` | int | PAM response limit; cap input at `maxResponseSize - 1` (AuthField does) |
| `dismissAvailable` | bool | Debug dismiss is enabled in this build (build-gated) |
| `submit()` | function | **The only unlock path** — submits the shared draft held in `auth.input` (zero arguments; a widget never supplies a password) |
| `dismiss()` | function | Debug dismiss — no-op unless `dismissAvailable` |

### `context.auth.input`

The one authoritative record of the editable response, owned by the context
so that themes can be promoted mid-typing without losing characters. The
shared `AuthField` core edits and renders it for you; read it for display
(e.g. a custom strength meter reads `text.length`), but never write the
properties directly and never log, serialize or transmit them.

| Member | Type | Meaning |
|---|---|---|
| `text` | string | Committed response draft (never display-mask characters) |
| `cursorPosition`, `anchorPosition` | int | Caret and the selection's fixed end (UTF-16 offsets); `selectionStart`/`selectionEnd` derive the ordered bounds |
| `revision` | int | Bumped on every authoritative change; the coherence signal for the draft record |
| `effectivePolicy`, `effectiveScope` | int | The latched initial-space tuning profile |
| `initialWindowOpen`, `tuningLatched` | bool | Tuning progress (survives view replacement) |

A genuinely custom input (not recommended) must implement the same writer
contract `AuthField` uses: register/claim a writer token, publish coherent
edits with `applyEdit`, respect `revision`, and request submission with
`context.auth.submit()` after synchronizing. `Modules/Lock/AuthField.qml`
is the reference implementation.

### Initial-space tunings

Some setups (e.g. a hotkey-driven lock where Space triggers the lock)
benefit from ignoring an initial accidental Space. The behavior is a
**tuning of the input core**, off by default, owned by the context so a
theme handoff mid-epoch neither double-consumes a key nor restarts the
filtering window. Set on the field; effective values latch at the first
interaction of the epoch and are shown via `auth.input.effectivePolicy`.

| `initialSpacePolicy` | Behavior |
|---|---|
| `AuthInputState policyPreserve` (default) | No suppression |
| `policyIgnoreFirst` | Consume Space only if it is the initial eligible editing key; its autorepeats are consumed until release. A later intentional Space inserts. |
| `policyIgnoreLeading` | Consume initial unmodified Space presses until the first accepted insertion (typing, paste or IME commit). Deleting back to empty does not reopen the window. |

`initialSpaceScope` controls the reset boundary: `scopeLock` (default) keeps
the epoch for the whole lock; `scopeResponse` starts a new epoch for each
consumed response. Paste and IME payloads are never trimmed or rewritten —
only delivered unmodified Space key events are filtered. Opt-in example:

```qml
// Ignore a stray initial Space press, for the whole lock.
LockModule.AuthField {
    id: field
    context: root.context
    initialSpacePolicy: context.auth.input.policyIgnoreFirst
    initialSpaceScope: context.auth.input.scopeLock
}
```

### `context.clock`

| Property | Type | Meaning |
|---|---|---|
| `now` | date | The wall clock, ticked every second — derive hours/minutes/rings from this; never your own timer |
| `time` | string | Locale short time |
| `date` | string | Locale short date |
| `timezone` | string | Abbreviation (e.g. `CEST`) |

### `context.video`

| Property | Type | Meaning |
|---|---|---|
| `id` | string | Asset id (cache filename stem), else `""` |
| `name` | string | `accessibilityLabel` from the pack manifest, else `""` |
| `secondaryName` | string | Manifest `title`, else `""` |
| `scene` | string | `city` / `nature` / …, else `""` |
| `timeOfDay` | string | `day` / `night` / …, else `""` |
| `sourceName` | string | The `sources[]` entry's name this clip came from |
| `path` | string | Currently playing file |
| `position` / `duration` | real | Seconds |
| `hasVideo` | bool | A frame is on screen |
| `accent` | color | d45: the frame's sensed prominent color, re-derived once per track (hue-bucketed histogram of a downscaled frame grab; saturated mid-tones win). `transparent` when unsensed — no video, gray/dark frame, or grab failure — so themes must keep a static fallback palette. Changes crossfade over 600 ms. |

### `context.poi`

| Property | Type | Meaning |
|---|---|---|
| `text` | string | Caption valid at `video.position`, else `""` |
| `at` | real | That caption's timestamp, or `-1` |

Community packs carry prose POI; Apple's manifests carry strings-bundle
keys that are not parsed yet, so Apple `poi.text` is `""`.

### `context.session`

| Property | Type | Meaning |
|---|---|---|
| `loginName` | string | The login being authenticated (the PAM user) |
| `avatarPath` | string | `$HOME/.face` absolute path, or `""` |
| `outputName` | string | Output the panel sits on |
| `layout` | string | Always `""` today (no documented API) |

### Presentation projections

So themes need neither ConfigStore nor Logger:

| Group | Contents |
|---|---|
| `context.panel` | `widthMax`, `fieldHeight`, `radius`, `fieldRadius`, `outerMargin`, `spacing`, `fontSize` |
| `context.colors` | `text`, `textError`, `input`, `panelFill`, `panelBorder`, `fieldFill`, `fieldBorderFocused`, `fieldBorder` |
| `context.labels` | `prompt`, `authenticating`, `authFailed`, `maxTries`, `authError`, `timedOut`, `dismissDebug`, `unlocked` (translated, English fallback) |

## Sampling and output lifetime

The production accent sampler settles a track for 1.5 seconds, then owns one
completion-driven command → image → paint transaction. It retries at most three
times and crossfades the resulting color over 600 ms. Canvas decodes within a
64×40 source-size bound and unloads the captured URL after painting or failure;
fresh temporary JPEGs retain the existing leftover-file policy. Track changes
retire interest without freeing an outstanding command's slot. A command deadline
does not cancel a file write or admit a replacement; real completion or receiver
retirement releases the slot. Video that appears only after the settle restarts
the settle once, never an immediate grab; a sensed, in-flight or exhausted track
is not sampled again when video availability toggles. Scenery failure leaves
authentication independent.

## Topic preference

A theme's `preferredTopics` biases which configured clips play: the lock
inventories every source once (completed clips only — a remote clip needs
its `.mp4` non-empty and its `.mp4.done` sibling), then matches whole
lowercased words. Remote clips match on manifest label/title/scene; local
clips on their filename. URL tokens, asset ids, POI keys and directory
names never match.

- Any declared topic matching a clip's words is enough (OR).
- Matches loop in original source order; no match or no topics plays the
  full pool.
- Matching is pure word logic (`Services/ThemeSelection.js`), not RAG.

## Trust and the fallback

Theme QML is **trusted executable code** running inside the lock — it is
not sandboxed. On any load failure (invalid filename, missing/unreadable
file, parse/import error, unmet required property, nonvisual root), the
lock shows the built-in panel and logs the path and reason. It never
unlocks, dismisses, quits, or touches PAM state because of a theme.

## Rules for themes

- Take the context in, draw it, keep the draft in `context.auth.input` via
  the shared core, and call `context.auth.submit()`.
- Keep the field disabled while `auth.inProgress`; re-arm focus when it
  clears (AuthField already does).
- Never depend on video/poi/clock content being non-empty.
- Delay nothing: no entrance animation may delay input or auth.
- Never log, serialize, transmit or dump `auth.input` contents (or any
  password material). The draft is plaintext in process memory while
  editing; that is a stated limitation, not an invitation to spread it.
