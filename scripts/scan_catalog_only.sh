#!/usr/bin/env bash
# scripts/scan_catalog_only.sh — enforces ADR-0018 (error catalog SSOT).
#
# Reports `setErrorFmt(` calls outside the catalog. Per ADR-0018 the
# catalog file `src/runtime/error_catalog.zig` is the only allowed
# caller of `error_mod.setErrorFmt(...)`. Other modules use
# `error_catalog.raise(.code, loc, args)`.
#
# Current mode: informational. The error-catalog migration (task 4.26)
# is the historical context — promotion to hard gate happens when
# `setErrorFmt(` hits outside the catalog drop to a stable 0 and the
# gate becomes a non-regressing guard.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck source=scan_lib.sh
source "$REPO_ROOT/scripts/scan_lib.sh"

scan_section "scan_catalog_only (ADR-0018 enforcement)"

# Count setErrorFmt calls in src/, EXCLUDING:
#   - error_catalog.zig (the catalog itself, allowed)
#   - error.zig (the setErrorFmt definition + its own test helper)
hits=$(grep -rn "setErrorFmt(" "$REPO_ROOT/src/" 2>/dev/null \
    | grep -v "/error_catalog\.zig:" \
    | grep -v "/error\.zig:.*pub fn setErrorFmt" \
    | grep -v "/error\.zig:.*setErrorFmt stores info" \
    | wc -l | tr -d ' ')

# Threshold: historical Phase 4 had ~110-116 raw setErrorFmt sites.
# Task 4.26 brought this toward 0 (modulo the catalog itself + the
# setErrorFmt definition). Tracking ongoing count for drift detection.
scan_report "scan_catalog_only" "$hits" 120

if (( hits > 0 )); then
    echo ""
    echo "Top 10 raise sites still using setErrorFmt directly:"
    grep -rn "setErrorFmt(" "$REPO_ROOT/src/" 2>/dev/null \
        | grep -v "/error_catalog\.zig:" \
        | grep -v "/error\.zig:.*pub fn setErrorFmt" \
        | sed -n 10p
fi
