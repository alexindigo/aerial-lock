# Theming (coming next)

> Status: **contract only.** There is no theme loader yet — a later plan adds
> one (`~/.config/aerial-lock/themes/`). This document records the object a
> theme will receive, so the contract is stable before the first consumer
> exists. Today's built-in panel (`Modules/Lock/LockContent.qml`) already
> reads exactly this object — no private back door.

A theme is a QML component with `required property LockContext context`. It
gets its data from the context and unlocks through it — it never touches
PAM, mpv, or the config directly. All strings are `""` and numbers `0`/`-1`
when unknown.

## `context.auth`

| Property / method | Type | Meaning |
|---|---|---|
| `status` | string | Current status message (prompt, "Authenticating…", failure) |
| `inProgress` | bool | A PAM transaction is running — keep the field disabled |
| `isError` | bool | The last attempt failed / errored (style `status` accordingly) |
| `responseVisible` | bool | PAM wants the answer echoed (echo-mode toggle) |
| `maxResponseSize` | int | PAM response limit; cap the input at `maxResponseSize - 1` |
| `submit(password)` | function | **The only unlock path.** Submits to the same PAM flow the built-in panel uses |
| `dismiss()` | function | Debug dismiss — no-op unless the build sets `debugAllowDismiss` |

## `context.clock`

| Property | Type | Meaning |
|---|---|---|
| `time` | string | Locale short time, ticked every second |
| `date` | string | Locale short date |
| `timezone` | string | Abbreviation (e.g. `CEST`) |

## `context.video`

| Property | Type | Meaning |
|---|---|---|
| `id` | string | Asset id (cache filename stem), else `""` |
| `name` | string | `accessibilityLabel` from the pack manifest, else `""` |
| `secondaryName` | string | Manifest `title`, else `""` |
| `scene` | string | `city` / `nature` / …, else `""` |
| `timeOfDay` | string | `day` / `night` / …, else `""` |
| `sourceName` | string | The `sources[]` entry's `name` this clip came from |
| `path` | string | Currently playing file |
| `position` | real | Seconds |
| `duration` | real | Seconds |
| `hasVideo` | bool | A frame is on screen |

## `context.poi`

| Property | Type | Meaning |
|---|---|---|
| `text` | string | Caption valid at `video.position`, else `""` |
| `at` | real | That caption's timestamp, or `-1` |

Captions come from the pack's `pointsOfInterest` (`{seconds: text}`) — the
latest entry not past the playhead. **Community packs carry prose and work
today. Apple's manifests carry keys into a binary strings bundle that is not
parsed yet (d38 deferred it — no C++ this slice), so Apple `poi.text` is
`""`.**

## `context.session`

| Property | Type | Meaning |
|---|---|---|
| `layout` | string | Keyboard layout — currently always `""` (no documented Qt/compositor QML API exposes it) |
| `outputName` | string | Output the panel sits on |

## Rules for themes

- Take the context in, draw it, call `context.auth.submit(password)` — that
  is all a theme may do.
- Keep the field disabled while `auth.inProgress`; re-arm focus when it
  clears.
- The panel must never depend on video/poi/clock content being non-empty.
