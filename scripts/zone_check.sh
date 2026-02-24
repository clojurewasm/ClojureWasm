#!/bin/bash
# Zone Check Script for ClojureWasm (Phase 97, D109)
# Counts cross-zone @import violations in the 4-zone architecture.
#
# Post-R8 zone mapping:
#   Layer 0: src/runtime/, src/regex/
#   Layer 1: src/engine/
#   Layer 2: src/lang/
#   Layer 3: src/app/
#
# Usage:
#   bash scripts/zone_check.sh           # Show violations (informational)
#   bash scripts/zone_check.sh --strict  # Exit 1 if any violations
#   bash scripts/zone_check.sh --gate    # Exit 1 if violations > baseline (commit gate)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Baseline: known violation count. Update when violations are fixed.
# History: 134 (R0) -> 126 (R9) -> 118 (Z1) -> 30 (Z2) -> 16 (Z3)
BASELINE=14

MODE="info"
if [[ "${1:-}" == "--strict" ]]; then
    MODE="strict"
elif [[ "${1:-}" == "--gate" ]]; then
    MODE="gate"
fi

ZONE_NAMES=("runtime" "engine" "lang" "app")

# Classify file path (relative to repo root) into zone 0-3
get_zone() {
    local file="$1"

    case "$file" in
        src/runtime/*|src/regex/*)   echo 0 ;;
        src/engine/*)                echo 1 ;;
        src/lang/*)                  echo 2 ;;
        src/app/*)                   echo 3 ;;
        *)                           echo 3 ;;
    esac
}

total_violations=0
declare -A bucket  # bucket["0->2"]=count

# Scan all .zig files under src/
while IFS= read -r src_file; do
    src_zone=$(get_zone "$src_file")
    src_dir=$(dirname "$src_file")

    # Extract @import("...") paths (only .zig files, skip std/builtin)
    while IFS= read -r import_path; do
        [[ -z "$import_path" ]] && continue

        # Resolve to repo-relative path
        target=$(realpath -m --relative-to=. "$src_dir/$import_path" 2>/dev/null) || continue
        [[ "$target" != src/* ]] && continue
        [[ ! -f "$target" ]] && continue

        tgt_zone=$(get_zone "$target")

        # Violation: importing from a higher layer
        if (( tgt_zone > src_zone )); then
            key="${src_zone}->${tgt_zone}"
            bucket["$key"]=$(( ${bucket["$key"]:-0} + 1 ))
            total_violations=$((total_violations + 1))
            echo "  VIOLATION: ${ZONE_NAMES[$src_zone]}($src_zone) -> ${ZONE_NAMES[$tgt_zone]}($tgt_zone): $src_file -> $import_path"
        fi
    done < <(grep -oP '@import\("\K[^"]+\.zig' "$src_file" 2>/dev/null || true)

done < <(find src/ -name '*.zig' -type f | sort)

echo ""
echo "=== Zone Violation Summary ==="
echo ""

if (( total_violations == 0 )); then
    echo "No violations found!"
else
    # Print buckets sorted
    for key in $(echo "${!bucket[@]}" | tr ' ' '\n' | sort); do
        src_z="${key%%->*}"
        tgt_z="${key##*->}"
        echo "  ${ZONE_NAMES[$src_z]}(L$src_z) -> ${ZONE_NAMES[$tgt_z]}(L$tgt_z): ${bucket[$key]} imports"
    done
    echo ""
    echo "Total violations: $total_violations (baseline: $BASELINE)"
fi

case "$MODE" in
    strict)
        if (( total_violations > 0 )); then
            echo ""
            echo "FAIL: Zone violations detected (--strict mode)"
            exit 1
        fi
        ;;
    gate)
        if (( total_violations > BASELINE )); then
            echo ""
            echo "FAIL: Zone violations increased ($total_violations > baseline $BASELINE)"
            echo "New upward imports are not allowed. Fix or use vtable pattern."
            exit 1
        elif (( total_violations < BASELINE )); then
            echo ""
            echo "Zone violations decreased ($total_violations < baseline $BASELINE)."
            echo "Update BASELINE in scripts/zone_check.sh to $total_violations."
        else
            echo ""
            echo "OK: Zone violations at baseline ($total_violations == $BASELINE)"
        fi
        ;;
esac

exit 0
