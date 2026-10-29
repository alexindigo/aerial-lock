#!/usr/bin/env bash
set -euo pipefail
root=$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")/../..")
exec bash "$root/Scripts/aerial-lock-run" --shell-dir "$root" --plugin-root "$root/native/qt-plugins"
