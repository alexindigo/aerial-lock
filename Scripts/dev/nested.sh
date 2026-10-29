#!/usr/bin/env -S bash
set -euo pipefail

# Nested-compositor sandbox for aerial-lock testing.
#
# usage: nested.sh [niri|hyprland] [--outputs N]
#
# Launches a nested niri or Hyprland as a window inside the running
# session, with the aerial-lock test binds pre-wired:
#
#   Mod+L              launch the guarded dev runner from this repo
#   Mod+Shift+Escape   niri's crash-test bind (does not unlock)
#   Mod+Shift+Q        quit the nested compositor (niri; when unlocked)
#
# (niri only allows spawn binds to fire while locked. Its crash-test bind
# does NOT unlock; Hyprland's bindl exit closes the nested compositor.)
#
# --outputs N  (hyprland only) adds N-1 headless fake outputs after
# startup, for multi-monitor testing without physical displays.
#
# Run in a disposable test VM. A secure lock remains locked after its client
# dies; use normal authentication or close only the owned nested compositor.
# The nested niri is started WITHOUT --session:
# --session would import the nested environment into the host's systemd
# and D-Bus and clobber WAYLAND_DISPLAY for newly-launched host apps.

usage() {
    echo "usage: $(basename -- "$0") [niri|hyprland] [--outputs N]" >&2
    exit 2
}

BACKEND="${1:-niri}"
[ $# -gt 0 ] && shift

OUTPUTS=1
while [ $# -gt 0 ]; do
    case "$1" in
        --outputs) OUTPUTS="${2:?--outputs needs a number}"; shift 2 ;;
        *) usage ;;
    esac
done

# Arithmetic below accepts a count, never an expression supplied by argv.
[[ "$OUTPUTS" =~ ^[1-9][0-9]*$ ]] || usage

case "$BACKEND" in
    niri|hyprland) ;;
    *) usage ;;
esac

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

TERMINAL=""
for t in ghostty alacritty kitty; do
    if command -v "$t" >/dev/null 2>&1; then TERMINAL="$t"; break; fi
done
[ -n "$TERMINAL" ] || { echo "nested.sh: no terminal found (install ghostty, alacritty or kitty)" >&2; exit 1; }

RUN_DIR="$(mktemp -d)"
trap 'rm -rf -- "$RUN_DIR"' EXIT

render() {
    sed -e "s|@REPO_ROOT@|$REPO_ROOT|g" -e "s|@TERMINAL@|$TERMINAL|g" "$1" > "$2"
}

case "$BACKEND" in
niri)
    CFG="$RUN_DIR/niri.kdl"
    render "$REPO_ROOT/Scripts/dev/nested/niri.kdl.in" "$CFG"
    niri validate -c "$CFG"
    niri -c "$CFG"
    ;;
hyprland)
    CFG="$RUN_DIR/hyprland.conf"
    render "$REPO_ROOT/Scripts/dev/nested/hyprland.conf.in" "$CFG"

    BEFORE="$(ls "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR not set}/hypr" 2>/dev/null | sort || true)"
    Hyprland -c "$CFG" &
    HYPID=$!

    SIG=""
    for _ in $(seq 1 50); do
        SIG="$(comm -13 <(printf '%s\n' "$BEFORE") <(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | sort) | head -1 || true)"
        [ -n "$SIG" ] && break
        kill -0 "$HYPID" 2>/dev/null || { echo "nested.sh: Hyprland exited early" >&2; exit 1; }
        sleep 0.2
    done
    [ -n "$SIG" ] || { echo "nested.sh: Hyprland instance did not appear" >&2; kill "$HYPID" 2>/dev/null || true; exit 1; }

    if [ "$OUTPUTS" -gt 1 ]; then
        # The instance socket appears before the compositor is ready to
        # create outputs — retry until hyprctl accepts commands.
        COUNT=0
        for _ in $(seq 1 25); do
            if hyprctl -i "$SIG" output create headless >/dev/null 2>&1; then
                COUNT=$((COUNT + 1))
                [ "$COUNT" -ge $((OUTPUTS - 1)) ] && break
            fi
            kill -0 "$HYPID" 2>/dev/null || { echo "nested.sh: Hyprland exited early" >&2; exit 1; }
            sleep 0.2
        done
    fi

    wait "$HYPID"
    ;;
esac
