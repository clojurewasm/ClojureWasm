#!/usr/bin/env bash
# file_size_check.sh — informational at Phase 4, gate at Phase 5-6 (ADR-0016).
# Reports files exceeding 1000 lines (soft) / 2000 lines (hard).
# Exempt marker: `FILE-SIZE-EXEMPT: <reason> (ADR-NNNN)` in file header.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SRC_DIR="$REPO_ROOT/src"

if [[ ! -d "$SRC_DIR" ]]; then
    exit 0
fi

SOFT=1000
HARD=2000

over_soft=()
over_hard=()

while IFS= read -r f; do
    lines=$(wc -l < "$f" | tr -d ' ')
    if grep -q "FILE-SIZE-EXEMPT" "$f" 2>/dev/null; then
        continue
    fi
    if (( lines > HARD )); then
        over_hard+=("$f ($lines lines)")
    elif (( lines > SOFT )); then
        over_soft+=("$f ($lines lines)")
    fi
done < <(find "$SRC_DIR" -name "*.zig" -type f)

if (( ${#over_soft[@]} > 0 )); then
    echo "[file_size_check] SOFT cap (>${SOFT}) exceeded:"
    printf "  %s\n" "${over_soft[@]}"
fi
if (( ${#over_hard[@]} > 0 )); then
    echo "[file_size_check] HARD cap (>${HARD}) exceeded:"
    printf "  %s\n" "${over_hard[@]}"
fi

# Phase 4 entry: informational only (exit 0 regardless).
# Phase 5-6 (post ADR-0016 landing): hard cap becomes gate (exit 1 if any over_hard).
exit 0
