#!/usr/bin/env bash
# scripts/scan_panic_audit.sh — enforces ADR-0019 (crash policy).
#
# Reports `@panic(` and `unreachable` usage under src/. Per ADR-0019
# they must be either:
#   - replaced with std.debug.assert (with a comment), or
#   - replaced with error_catalog.raise(.internal_error, ...), or
#   - kept with a `// @panic: <reason>` justification comment.
#
# Phase 4 entry: informational. Phase 5+: gate per ADR-0019.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck source=scan_lib.sh
source "$REPO_ROOT/scripts/scan_lib.sh"

scan_section "scan_panic_audit (ADR-0019 enforcement)"

# grep returns 1 when there are no matches; pipe to wc -l so set -e
# does not abort on a clean source tree.
panic_hits=$( { grep -rn "@panic(" "$REPO_ROOT/src/" || true; } | wc -l | tr -d ' ')
unreach_hits=$( { grep -rnE '\bunreachable\b' "$REPO_ROOT/src/" || true; } | wc -l | tr -d ' ')

# Threshold: ADR-0019 estimates ~4 unreachable + 0 @panic at Phase 4
# entry. Each hit must carry a justification comment.
scan_report "scan_panic_audit @panic"     "$panic_hits"   5
scan_report "scan_panic_audit unreachable" "$unreach_hits" 20

if (( panic_hits + unreach_hits > 0 )); then
    echo ""
    echo "@panic / unreachable sites (must carry justification per ADR-0019):"
    grep -rn "@panic(" "$REPO_ROOT/src/" 2>/dev/null || true
    grep -rnE '\bunreachable\b' "$REPO_ROOT/src/" 2>/dev/null || true
fi
