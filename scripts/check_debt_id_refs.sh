#!/usr/bin/env bash
# scripts/check_debt_id_refs.sh
#
# Recurrence guard from the 2026-05-31 tech-debt consolidation audit
# (memory 20260911004940-38e9586e, failure mode M5). Every `D-NNN`
# referenced in source / docs MUST resolve to an entry in `.dev/debt.yaml`;
# a phantom ID (`D-NEW`, a typo, a never-filed placeholder) silently
# detaches the comment that cites it from the Step-0.5 trigger system.
#
# Also prints the open `quality-loop floor:` backlog so the F-010
# quality loop sees how many standing correctness/coverage rows remain
# to drain (CLAUDE.md Step 0.5 "Quality-loop floor drain").
#
# Informational by default (exit 0). Pass --gate to exit 1 on a
# violation (for future wiring into test/run_all.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/hook_lib.sh"

DEBT=.dev/debt.yaml
gate=0
[ "${1:-}" = "--gate" ] && gate=1

# 0. debt.yaml MUST be valid YAML. The ID checks below are grep-based, so a
# malformed SSOT (e.g. an unbalanced quote in a `status:` prose string) would
# pass them silently while breaking every yq consumer (audit_scaffolding, the
# yaml_ssot_yq cookbook). Guard it here -- the cheapest place the SSOT is read.
# (2026-06-14: a D-425 status edit left an unbalanced ", and the grep-based
# checks + gate stayed green for 6 commits while yq could not parse the file.)
if command -v yq >/dev/null 2>&1; then
  if ! yq -r '.active | length' "$DEBT" >/dev/null 2>&1; then
    echo "check_debt_id_refs: VIOLATION -- $DEBT is not valid YAML (yq parse failed)." >&2
    [ "$gate" -eq 1 ] && exit 1
  fi
fi

# Files that may legitimately cite a debt ID. Exclude debt.yaml itself
# (it defines + cross-references IDs) and the audit scratch notes.
search_paths=(src .dev .claude scripts test data/feature_deps.yaml data/placement.yaml data/compat_tiers.yaml)
# debt.yaml itself defines + discusses IDs (incl. phantom ones it tracks for
# repair), so it is not a citation site; the consolidation doc + audit notes
# likewise describe phantoms by name. `.dev/decisions/` (ADRs) are excluded
# because an ADR is an APPEND-ONLY decision record that may quote a Devil's-
# advocate's text or a then-proposed placeholder ID verbatim — requiring every
# ID in immutable history to resolve to a live row fights that immutability,
# and ADRs do not drive the Step-0.5 trigger system (debt.yaml rows do). The
# check guards LIVE trigger sites (src + live docs), not history.
exclude='\.dev/debt\.ya?ml|audit-lens|check_debt_id_refs\.sh'

# A git worktree nested inside this checkout (e.g. `.claude/worktrees/<branch>`)
# is a DIFFERENT checkout: its `src` / `.dev` / `scripts` sit under a scan root
# above, so an unguarded walk reports that branch's citations as this one's.
# Excluded by path, derived from `git worktree list` — never hardcoded.
wt_globs=()
while IFS= read -r _arg; do
  [[ -n "$_arg" ]] && wt_globs+=("$_arg")
done < <(hook_rg_exclude_worktrees)

# 1. Phantom placeholder IDs — never a real row.
phantom=$(rg -n --no-heading ${wt_globs[@]+"${wt_globs[@]}"} 'D-NEW[A-Z0-9-]*' "${search_paths[@]}" 2>/dev/null \
  | rg -v "$exclude" || true)

# 2. Real-looking D-NNN refs with no entry in debt.yaml.
# `\b` so "PID-1" / "JDK-19"-style substrings don't masquerade as a debt ref.
# zwasm's own ledger ids are cited as `zwasm/D-NNN` (namespace-qualified) and
# are not cljw citations: the two ledgers share the D-NNN shape and already
# collide on D-585, so a bare id is ALWAYS a cljw row and the qualified form is
# stripped before extraction. The line-level `rg -v` cannot do that (a line may
# cite both), hence the sed on the matched text.
defined=$(rg -o '\bD-[0-9]+' "$DEBT" 2>/dev/null | sort -u || true)
referenced=$(rg -o --no-heading ${wt_globs[@]+"${wt_globs[@]}"} '(zwasm/)?\bD-[0-9]+' "${search_paths[@]}" 2>/dev/null \
  | rg -v "$exclude" | sed -E 's#zwasm/D-[0-9]+##' | grep -o 'D-[0-9]\+' | sort -u || true)
missing=""
for id in $referenced; do
  # Herestring, NOT `printf | grep -q`: grep -q exits on first match, and
  # under `set -o pipefail` printf's EPIPE then fails the pipeline —
  # sporadically misclassifying a DEFINED id as missing (2026-07-02 nightly:
  # false "UNDEFINED D-196 D-230" with `printf: write error: Broken pipe`).
  grep -qx "$id" <<< "$defined" || missing="$missing $id"
done

# 3. quality-loop floor backlog — the number CLAUDE.md Step 0.5 drains
# easiest-first, so it has to mean what it says. It counted the WHOLE file,
# discharged rows included, and reported the total as "open rows": 21 against
# an actual 6 (17 of the matches were in `discharged:`, and `grep -c` counts
# lines rather than occurrences, hence 21 rather than 23). A backlog number
# inflated 7x by finished work is the ledger-rot failure the discipline exists
# to prevent, wearing the counter instead of the rows.
#
# The unit is ROWS, not matching lines: one row can name the floor several
# times (D-210 does, four times) and would otherwise count as four items of
# backlog.
floor=$(awk '
    /^active:/     { a = 1; next }
    /^discharged:/ { if (a && hit) n++; a = 0; hit = 0 }
    a && /^  - id:/            { if (hit) n++; hit = 0 }
    a && /quality-loop floor:/ { hit = 1 }
    END { if (a && hit) n++; print n + 0 }
' "$DEBT")

bad=0
if [ -n "$phantom" ]; then
  echo "check_debt_id_refs: PHANTOM debt IDs (no such row in $DEBT):"
  printf '%s\n' "$phantom"
  bad=1
fi
if [ -n "${missing// /}" ]; then
  echo "check_debt_id_refs: UNDEFINED debt IDs referenced (not in $DEBT):$missing"
  bad=1
fi
echo "check_debt_id_refs: quality-loop floor open rows = ${floor:-0}"
if [ "$bad" = 1 ]; then
  echo "check_debt_id_refs: VIOLATIONS found (see above)"
  [ "$gate" = 1 ] && exit 1
  exit 0
fi
echo "check_debt_id_refs: ok — all cited debt IDs resolve"
