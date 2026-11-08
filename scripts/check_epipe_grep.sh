#!/usr/bin/env bash
# check_epipe_grep.sh — `echo "$value" | grep -q` in a `set -eo pipefail` gate
# script is a false-failure trap. Forbid it; `grep -q … <<<"$value"` is the
# replacement.
#
#   bash scripts/check_epipe_grep.sh
#
# `grep -q` exits on its first match. If the producer still has bytes to write
# (a value larger than the pipe buffer, or a loaded host that schedules the
# reader first), the producer takes SIGPIPE, the pipeline exits 141, `pipefail`
# propagates it, and the `|| fail …` on the same line reports a MISS for a
# line that is visibly present in the output it then prints. Observed
# 2026-09-05 in `e2e_phase16_wasm_memory` (full gate red, two direct re-runs
# green) and 2026-07-02 in `check_debt_id_refs.sh`.
#
# A herestring has no pipe and no second process, so there is nothing to
# race. It is available wherever the value is already in a shell variable,
# which is every site this check covers: only the `echo`/`printf` value-fed
# shape is flagged. A command-fed `cmd | grep -q` is a different case (its
# producer's exit status is the thing to decide about) and is left to review.
# A genuinely-justified other case marks its line `# epipe-ok: <reason>`.
#
# Sibling of check_epipe_head.sh (same hazard class, the `head -N` shape).
set -euo pipefail
cd "$(dirname "$0")/.."

MARKER='# epipe-ok:'
bad=0

while IFS=: read -r file lineno line; do
    [[ -z "$file" ]] && continue
    [[ "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" == \#* ]] && continue
    [[ "$line" == *"$MARKER"* ]] && continue
    bad=$((bad + 1))
    echo "check_epipe_grep: $file:$lineno feeds a shell value through a pipe into 'grep -q' under pipefail." >&2
    echo "  → $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-110)" >&2
done < <(grep -rnE '(echo|printf)[[:space:]]+[^|]*"\$[A-Za-z_][A-Za-z0-9_]*"[[:space:]]*\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' test/e2e scripts bench --include='*.sh' 2>/dev/null || true)

if [[ "$bad" -gt 0 ]]; then
    echo "  Use a herestring instead: grep -q <pattern> <<<\"\$value\" (no pipe, nothing to race)." >&2
    echo "  If a case is genuinely safe, mark the line '$MARKER <reason>'." >&2
    exit 1
fi
echo "    epipe_grep: no value-fed 'grep -q' pipe under pipefail in test/e2e, scripts or bench"
