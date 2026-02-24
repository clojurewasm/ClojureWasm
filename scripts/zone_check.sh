#!/bin/bash
# Zone Check Script for ClojureWasm (Phase 97, D109)
# Counts cross-zone @import violations in the 4-zone architecture.
#
# Pre-R8 zone mapping:
#   Layer 0: src/runtime/, src/regex/
#            (excluding runtime/{bootstrap,eval_engine,pipeline,cache,embedded_sources}.zig)
#   Layer 1: src/reader/, src/analyzer/, src/compiler/, src/evaluator/, src/vm/
#            + src/runtime/{bootstrap,eval_engine,pipeline,cache,embedded_sources}.zig
#   Layer 2: src/builtins/, src/interop/
#   Layer 3: src/main.zig, src/deps.zig, src/repl/, src/wasm/
#
# Usage:
#   bash scripts/zone_check.sh          # Show violations
#   bash scripts/zone_check.sh --strict  # Exit 1 if any violations

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

STRICT=false
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=true
fi

ZONE_NAMES=("runtime" "engine" "lang" "app")

# Layer 1 files that live in src/runtime/ (pre-R8 exception)
LAYER1_RUNTIME="bootstrap.zig eval_engine.zig pipeline.zig cache.zig embedded_sources.zig"

# Classify file path (relative to repo root) into zone 0-3
get_zone() {
    local file="$1"

    # Layer 1 exceptions in runtime/
    for special in $LAYER1_RUNTIME; do
        if [[ "$file" == "src/runtime/$special" ]]; then
            echo 1
            return
        fi
    done

    case "$file" in
        src/runtime/*|src/regex/*)                              echo 0 ;;
        src/reader/*|src/analyzer/*|src/compiler/*|             \
        src/evaluator/*|src/vm/*)                               echo 1 ;;
        src/builtins/*|src/interop/*)                           echo 2 ;;
        src/main.zig|src/deps.zig|src/repl/*|src/wasm/*)       echo 3 ;;
        *)                                                      echo 3 ;;
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
    echo "Total violations: $total_violations"
fi

if $STRICT && (( total_violations > 0 )); then
    echo ""
    echo "FAIL: Zone violations detected (--strict mode)"
    exit 1
fi

exit 0
