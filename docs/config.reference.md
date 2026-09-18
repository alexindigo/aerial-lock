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
| `pamService`       | string  | `"aerial-lock"`  | PAM config under `/etc/pam.d/`                 |
| `fallbackQuitMs`   | number  | `3000`           | Force-quit after unlock if compositor ack fails|
| `debugAllowDismiss`| boolean | `false`          | **INSECURE** — show dismiss button (dev only)  |

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

## Known limitations

- **No PAM account-management phase.** Quickshell's `PamContext` runs
  `pam_authenticate` only, so interactive account-management flows (e.g. an
  expired password's "new password/retype" prompt) are unreachable — identical
  to swaylock and hyprlock, which are also auth-only. A plain expired password
  still authenticates correctly.
- **Plaintext password lifetime.** The password is held as a QML string
  (`pendingPassword`): it lives on the JS heap, cannot be zeroed, and a
  cleared value survives until garbage collection. The property is cleared
  *before* `respond()` is called, so it holds a value only across the async
  gap between submit and the first PAM prompt — typically milliseconds. The
  exposure is narrowed, not eliminated; a real fix needs an `mlock`ed buffer
  behind a C++ helper.

## Recovery

The supervisor (`aerial-lock-supervisor`, what `aerial-lock` execs) owns the
locker lifecycle: spawns the QML locker, respawns on abnormal death (limit
**3**, short backoff), and when respawns run out **stays locked** — there is
no automatic unlock. Exit `0` means clean unlock / PAM refusal / external
invalidation; anything else respawns. Manual recovery is `aerial-unlock`
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

## Debug / development

### `debugAllowDismiss`

Setting to `true` adds a "Dismiss (debug)" button that bypasses all
authentication. **This is a security risk.** Only enable during development
or testing, and never on a production system.

### Environment overrides

| Variable                    | Overrides      | Purpose                        |
|-----------------------------|----------------|--------------------------------|
| `AERIAL_LOCK_PAM_SERVICE`   | `pamService`   | Dev testing without installing PAM file |

Example:
```
AERIAL_LOCK_PAM_SERVICE=login qs -p .
```

## Example

```json
{
  "language": "en",
  "backgroundColor": "#1a1a2e",
  "pamService": "login",
  "fallbackQuitMs": 3000,
  "debugAllowDismiss": false,
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

Additional fields will be added in future phases for video sources, overlays,
and idle behavior.
