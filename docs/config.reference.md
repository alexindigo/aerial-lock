# aerial-lock Configuration Reference

`~/.config/aerial-lock/config.json` is created automatically on first launch
with defaults.

Bundled defaults are at `/usr/share/aerial-lock/Config/defaults.json`.
User override at `~/.config/aerial-lock/config.json`.

Each field follows strict JSON types (numbers are numbers, strings are strings,
objects are objects). Type mismatches cause the field to fall back to its
bundle default.

## Fields

### Top-level

| Field              | Type    | Default          | Description                                    |
|--------------------|---------|------------------|------------------------------------------------|
| `language`         | string  | `"en"`           | I18n language (`en.json`, future `ru.json`)    |
| `backgroundColor`  | string  | `"#000000"`      | Solid color when no video. CSS hex.            |
| `pamService`       | string  | `"aerial-lock"`  | PAM config under `/etc/pam.d/`                 |
| `fadeMs`           | number  | `300`            | Fade-out duration on unlock, in milliseconds   |
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
different file (e.g. `"ru"` for `i18n/ru.json`). Falls back to `en` if the
requested language is missing.

User overrides at `~/.config/aerial-lock/i18n/<lang>.json` take precedence
over bundle defaults.

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
  "fadeMs": 200,
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
