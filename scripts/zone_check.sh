#!/usr/bin/env bash
# Zone dependency checker.
#
# Enforces the layering rules in .claude/rules/zone_deps.md:
#   Layer 0 (runtime/) must NOT import from Layer 1+ (eval/, lang/, modules/, app/)
#   Layer 1 (eval/)    must NOT import from Layer 2+ (lang/, modules/, app/)
#   Layer 2 (lang/)    must NOT import from Layer 3 (app/)
#
# Modes:
#   bash scripts/zone_check.sh           informational; always exits 0
#   bash scripts/zone_check.sh --strict  exit 1 on any violation
#   bash scripts/zone_check.sh --gate    exit 1 if violations exceed BASELINE
#
# Test blocks (everything after the first `test "..."` line in a file)
# are skipped — test code may legitimately cross zones.

set -euo pipefail

BASELINE=0
MODE="${1:-info}"

cd "$(dirname "$0")/.."

zone_of() {
    local path="$1"
    case "$path" in
        src/runtime/*)            echo 0 ;;
        src/eval/*)               echo 1 ;;
        src/lang/*)               echo 2 ;;
        src/app/*|src/main.zig)   echo 3 ;;
        modules/*)                echo 2 ;;
        *)                        echo "x" ;;
    esac
}

violations_file=$(mktemp)
trap "rm -f $violations_file" EXIT

# `find` returns 0 even when no files match; `|| true` is for safety.
files="$(find src modules -name '*.zig' 2>/dev/null || true)"

for file in $files; do
    src_zone=$(zone_of "$file")
    [ "$src_zone" = "x" ] && continue

    # grep exits 1 when no @import matches; that is not a failure here.
    awk '/^test "/{exit} {print NR ":" $0}' "$file" \
        | { grep -E '@import\("[^"]+\.zig"\)' || true; } \
        | while IFS=: read -r lineno content; do
            import_path=$(echo "$content" | sed -nE 's/.*@import\("([^"]+)"\).*/\1/p')
            [ -z "$import_path" ] && continue
            case "$import_path" in
                std|builtin) continue ;;
            esac

            # Resolve the imported file relative to the importing file.
            file_dir=$(dirname "$file")
            resolved=$(cd "$file_dir" 2>/dev/null && cd "$(dirname "$import_path")" 2>/dev/null && pwd)/$(basename "$import_path")
            rel=$(realpath --relative-to="$(pwd)" "$resolved" 2>/dev/null || echo "$resolved")

            tgt_zone=$(zone_of "$rel")
            [ "$tgt_zone" = "x" ] && continue

            if [ "$src_zone" -lt "$tgt_zone" ]; then
                echo "$file:$lineno: zone $src_zone imports zone $tgt_zone ($import_path)" \
                    >> "$violations_file"
            fi
        done
done

count=$(wc -l < "$violations_file" | tr -d ' ')

if [ "$count" -gt 0 ]; then
    cat "$violations_file"
    echo
    echo "$count zone violation(s) found."
fi

case "$MODE" in
    --strict)
        if [ "$count" -gt 0 ]; then exit 1; fi
        ;;
    --gate)
        if [ "$count" -gt "$BASELINE" ]; then
            echo "Gate failed: $count > BASELINE=$BASELINE" >&2
            exit 1
        fi
        ;;
    *)
        echo "(informational mode: exit 0 regardless of violations)"
        ;;
esac

exit 0
