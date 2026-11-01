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
# Use NUL-delimited tracked paths, including extensionless launchers and hooks.
# Keep this in the shared entry point so the hook and CI discover the same set.
git ls-files -z | {
    shell_scripts=()
    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        first_line=''
        IFS= read -r first_line < "$file" || true
        if [[ "$file" == *.sh || "$first_line" =~ ^\#!.*(/|[[:space:]])(ba)?sh([[:space:]]|$) ]]; then
            shell_scripts+=("./$file")
        fi
    done
    printf 'ShellCheck: %s scripts\n' "${#shell_scripts[@]}"
    if ((${#shell_scripts[@]})); then
        shellcheck -- "${shell_scripts[@]}"
    fi
}
if [[ "${1:-}" == --hook ]]; then
    git diff --cached --check
fi
