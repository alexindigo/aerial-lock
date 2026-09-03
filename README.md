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

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
