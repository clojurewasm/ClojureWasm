#!/usr/bin/env bash
# check_epipe_head.sh — `| head -N` fed by a COMMAND is a silent-death trap in
# a `set -eo pipefail` script. Forbid it; `sed -n Np` is the replacement.
#
#   bash scripts/check_epipe_head.sh
#
# `head -N` closes the pipe as soon as it has N lines. If the producer is still
# running it takes SIGPIPE, the pipeline exits 141, `pipefail` propagates that,
# and `set -e` kills the script — BEFORE the comparison that would have printed
# a diagnostic. The failure surfaces as a bare `[fail] (exit 1, 0s)` with no
# message, on a loaded machine, in a step that passes everywhere else.
#
# `sed -n Np` reads to EOF, so the writer never sees a closed pipe.
#
# History, which is the reason this is a gate and not a note: `ab84126b`
# (2026-08-04) diagnosed exactly this on a loaded x86_64-linux CI runner and
# hardened the FOUR sites it knew about. It defined no discovery criterion and
# left no check, so the population kept 24 more — and a new e2e written the same
# afternoon reintroduced it and failed CI while passing on two other machines.
# A one-off fix for a mechanical hazard is a fix for the instances someone
# remembered (`memory 20260909234612-6f9c927b (framework_completion)`).
#
# Exempt: a pipeline whose producer is `printf` or `echo` of a shell value. That
# is a single write into the pipe buffer with no later flush, so there is no
# window in which SIGPIPE can arrive — the same carve-out `ab84126b` states.
# A genuinely-justified other case marks its line `# epipe-ok: <reason>`.
set -euo pipefail
cd "$(dirname "$0")/.."

MARKER='# epipe-ok:'
bad=0

while IFS=: read -r file lineno line; do
    [[ -z "$file" ]] && continue
    # Comment lines are prose about the hazard, not the hazard.
    [[ "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" == \#* ]] && continue
    [[ "$line" == *"$MARKER"* ]] && continue
    # Single-write producers cannot lose a SIGPIPE race.
    grep -qE '(printf|echo)[[:space:]]+[^|]*\|[[:space:]]*head -[0-9]' <<<"$line" && continue
    bad=$((bad + 1))
    echo "check_epipe_head: $file:$lineno pipes a command into 'head -N' under pipefail." >&2
    echo "  → $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-110)" >&2
done < <(grep -rnE '\|[[:space:]]*head -[0-9]' test/e2e scripts bench --include='*.sh' 2>/dev/null || true)

if [[ "$bad" -gt 0 ]]; then
    echo "  Use 'sed -n Np' instead — it reads to EOF, so the producer never sees a closed pipe." >&2
    echo "  If a case is genuinely safe, mark the line '$MARKER <reason>'." >&2
    exit 1
fi
echo "    epipe_head: no command-fed 'head -N' under pipefail in test/e2e, scripts or bench"
