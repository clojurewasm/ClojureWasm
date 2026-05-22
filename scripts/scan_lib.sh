#!/usr/bin/env bash
# scripts/scan_lib.sh — shared helpers for source-scan gates.
# Per ADR-0024.
#
# Usage from a scan script:
#   source "$(dirname "${BASH_SOURCE[0]}")/scan_lib.sh"
#   scan_section "my_gate"
#   hits=$(scan_count "forbidden_pattern" "$REPO_ROOT/src/")
#   scan_report "my_gate" "$hits" 0

# Mode: "informational" (Phase 4 default) or "gate" (Phase 5+ default).
# Per-script overrides via env: CLJW_SCAN_MODE=gate bash scripts/scan_*.sh
scan_mode() {
    echo "${CLJW_SCAN_MODE:-informational}"
}

scan_section() {
    local title="$1"
    echo ""
    echo "=== $title (mode: $(scan_mode)) ==="
}

# Count pattern hits across a directory.
scan_count() {
    local pattern="$1"
    local dir="$2"
    grep -rn "$pattern" "$dir" 2>/dev/null | wc -l | tr -d ' '
}

# List pattern hits across a directory (file:line: line).
scan_match_in_dir() {
    local pattern="$1"
    local dir="$2"
    grep -rn "$pattern" "$dir" 2>/dev/null
}

# Print a pass/fail line and return 0 (informational mode never fails)
# or threshold-checked exit (gate mode).
scan_report() {
    local gate_name="$1"
    local hits="$2"
    local threshold="${3:-0}"

    if (( hits > threshold )); then
        echo "[$gate_name] hits=$hits (threshold=$threshold) -- OVER"
        if [[ "$(scan_mode)" == "gate" ]]; then
            return 1
        fi
    else
        echo "[$gate_name] hits=$hits (threshold=$threshold) -- OK"
    fi
    return 0
}
