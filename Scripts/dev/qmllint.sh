#!/usr/bin/env -S bash
set -euo pipefail

# QML Linter Script — runs Qt6 qmllint with aerial-lock import paths.

export QT_LOGGING_RULES="qt.qmldom.*=false"

# Find qmllint binary
QMLLINT=""
for path in "/usr/lib64/qt6/bin/qmllint" "/usr/lib/qt6/bin/qmllint"; do
    if [ -x "$path" ]; then
        QMLLINT="$path"
        break
    fi
done

if [ -z "$QMLLINT" ] && command -v qmllint &>/dev/null; then
    QMLLINT="qmllint"
fi

if [ -z "$QMLLINT" ]; then
    echo "No 'qmllint' found in standard locations or PATH." >&2
    echo "Install via 'qt6-declarative-tools' or equivalent." >&2
    exit 1
fi

QMLLINT_VERSION=$("$QMLLINT" --version 2>&1 || echo "unknown")
if [[ ! "$QMLLINT_VERSION" =~ ^qmllint\ [6-9]\. ]]; then
    echo "qmllint version $QMLLINT_VERSION is too old." >&2
    echo "Install Qt 6.6+ qmllint via 'qt6-declarative-tools' or equivalent." >&2
    exit 1
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
IMPORT_OPTS=(-I "$REPO_ROOT" -I /usr/lib/qt6/qml/ -I /usr/lib/qt6/qml/Quickshell/)

# Categories enforced as errors, beyond those qmllint exits non-zero for.
ENFORCED_CATEGORIES=(
    missing-type
    unresolved-alias
    unintentional-empty-block
    read-only-property
    confusing-expression-statement
    alias-cycle
    duplicate-property-binding
    assignment-in-condition
    property-override
    syntax
)

# A find root is a literal pathname, never an option or an expression (even
# names such as -delete, '(' or '!'). Keep filenames NUL-delimited through
# collection so whitespace and newlines remain part of their one operand.
roots=()
[ $# -gt 0 ] || set -- .
for root in "$@"; do
    [[ -e "$root" ]] || { printf 'qmllint: root does not exist: %s\n' "$root" >&2; exit 2; }
    case "$root" in
        .|./*|/*) roots+=("$root") ;;
        *) roots+=("./$root") ;;
    esac
done
file_list=$(mktemp)
trap 'rm -f -- "$file_list"' EXIT
find "${roots[@]}" -name '*.qml' -type f ! -path './.git/*' -print0 | sort -z > "$file_list"
mapfile -d '' -t all_files < "$file_list"

[ ${#all_files[@]} -eq 0 ] && { echo "No QML files found"; exit 0; }

echo "Linting ${#all_files[@]} QML files..."
ec=0
output=$("$QMLLINT" "${IMPORT_OPTS[@]}" "${all_files[@]}" 2>&1) || ec=$?

has_errors=0

# Check exit code — qmllint may exit non-zero for hard errors.
[ $ec -ne 0 ] && has_errors=1

# Check explicitly enforced categories (these may not always cause
# non-zero exit from qmllint itself, especially in Qt 6.11).
# Only matches Warning/Error lines to respect .qmllint.ini severity.
for cat in "${ENFORCED_CATEGORIES[@]}"; do
    if grep -E "^(Warning|Error):.*\[$cat\]" <<< "$output" >/dev/null 2>&1; then
        has_errors=1
        break
    fi
done

if [ -n "$output" ]; then
    echo "$output" >&2
fi

if [ $has_errors -eq 1 ]; then
    echo "qmllint: FAILED" >&2
    exit 1
fi

echo "qmllint: clean"
