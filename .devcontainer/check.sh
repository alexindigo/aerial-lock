#!/usr/bin/env bash
set -euo pipefail

# Lint only. Builds, tests and runtime verification belong in the project VM.
case "${1:-}" in
    ''|--hook) ;;
    *) printf 'usage: %s [--hook]\n' "$0" >&2; exit 2 ;;
esac

# Command-scoped trust works for root in CI without modifying the read-only repo.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$PWD"

Scripts/dev/qmllint.sh .
# Repository-wide shellcheck is not clean yet (SC2012 in Scripts/dev/nested.sh).
if [[ "${1:-}" == --hook ]]; then
    git diff --cached --check
fi
