#!/usr/bin/env bash
# G2 gate (ADR-0029 D4): Backend marker docstring required on every
# Java/cljw surface file.
#
# Every src/runtime/java/**/*.zig and src/runtime/cljw/**/*.zig file
# must open with three lines after the module docstring:
#
#   //! Backend: <impl-only | collection-only | impl+collection | surface-only>
#   //! Impl deps: <comma-separated keywords or "none">
#   //! Clojure peer: <ns/var or "none">
#
# Exceptions (markers / docs, not surface files):
#   _host_api.zig
#   _README.md
#
# See .claude/rules/feature_name_consistency.md R2 for the contract.
#
# Modes (mirror zone_check.sh):
#   bash scripts/check_surface_marker.sh           informational; exits 0
#   bash scripts/check_surface_marker.sh --strict  exit 1 on any violation
#   bash scripts/check_surface_marker.sh --gate    exit 1 on any violation
#                                                  (gate == strict here)

set -euo pipefail

MODE="${1:-info}"

cd "$(dirname "$0")/.."

violations_file=$(mktemp)
trap "rm -f $violations_file" EXIT

# Pattern: surface .zig files under runtime/java/ or runtime/cljw/
# (skip _host_api.zig).
files="$(find src/runtime/java src/runtime/cljw -name '*.zig' \
            -not -name '_host_api.zig' 2>/dev/null || true)"

for file in $files; do
    # Read the first 20 lines (markers must appear at the top).
    head_lines="$(head -n 20 "$file")"

    # here-string (not `printf | grep -q`): grep -q short-circuits on the
    # first match and closes the pipe, so a still-writing printf hits SIGPIPE
    # and, under `pipefail`, the pipeline returns non-zero — `if !` then
    # inverts that into a phantom "missing marker" violation (macOS-nightly
    # timing exposed it; a marker-present file reported as missing).
    if ! grep -qE '^//! Backend: (impl-only|collection-only|impl\+collection|surface-only)$' <<<"$head_lines"; then
        echo "$file: G2/ADR-0029 D4: missing or malformed 'Backend:' marker" >> "$violations_file"
    fi
    if ! grep -qE '^//! Impl deps: ' <<<"$head_lines"; then
        echo "$file: G2/ADR-0029 D4: missing 'Impl deps:' marker" >> "$violations_file"
    fi
    if ! grep -qE '^//! Clojure peer: ' <<<"$head_lines"; then
        echo "$file: G2/ADR-0029 D4: missing 'Clojure peer:' marker" >> "$violations_file"
    fi
done

count=$(wc -l < "$violations_file" | tr -d ' ')

if [ "$count" -gt 0 ]; then
    cat "$violations_file"
    echo
    echo "$count surface marker violation(s) found."
fi

case "$MODE" in
    --strict|--gate)
        if [ "$count" -gt 0 ]; then exit 1; fi
        ;;
    *)
        echo "(informational mode: exit 0 regardless of violations)"
        ;;
esac

exit 0
