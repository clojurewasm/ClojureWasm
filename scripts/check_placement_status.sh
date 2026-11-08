#!/usr/bin/env bash
# check_placement_status.sh — the placement-drift gate (ADR-0178).
#
#   bash scripts/check_placement_status.sh            # gate: regenerate + diff
#   bash scripts/check_placement_status.sh --summary  # print the impl breakdown
#
# `data/placement.yaml` is GENERATED from the running runtime
# (`scripts/gen_placement.sh` → `(cljw.internal/__dump-placement)`). This gate
# regenerates it and fails on any difference, so the checked-in index cannot
# disagree with the code. Wired into `test/run_all.sh` as `placement_drift`.
#
# What replaced what (ADR-0178): the previous version of this script audited a
# HAND-WRITTEN placement.yaml and proposed `status:` flips for an ADR-0033
# Pattern A/B migration schedule. That schedule completed — D-062 was discharged
# 2026-05-27 with `clojure.string/escape` as the sole residual (now D-094) — but
# the ledger never followed: 42 rows still read `transient_zig` for vars whose
# `.clj` bodies had shipped. It also covered 49 of ~683 `clojure.core` publics,
# cited two helper scripts that never existed, and was wired into no gate at
# all. The schedule is done; what remains is a fact about the code, so it is
# derived and gated rather than maintained and trusted.
#
# Intent — "this var's CURRENT placement is not its INTENDED one" — is a
# judgement, not a fact, and is not recorded here. It lives in `.dev/debt.yaml`
# with a barrier (today exactly one row, D-094). ADR-0033 D2-D5 remains the
# placement rule this index reports against.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

YAML="data/placement.yaml"

if [[ "${1:-}" == "--summary" ]]; then
    [ -f "$YAML" ] || { echo "check_placement_status: $YAML missing — run scripts/gen_placement.sh" >&2; exit 1; }
    echo "== placement summary ($YAML)"
    sed -n '/^summary:/,/^vars:/p' "$YAML" | grep -v '^vars:'
    echo "== per-namespace impl counts"
    grep '^  "' "$YAML" \
      | sed 's/^  "\([^/]*\)\/.*impl: \([a-z]*\).*/\1 \2/' \
      | sort | uniq -c \
      | awk '{printf "  %-26s %-8s %s\n", $2, $3, $1}'
    exit 0
fi

if [[ ! -f "$YAML" ]]; then
    echo "check_placement_status: $YAML missing — run 'bash scripts/gen_placement.sh'" >&2
    exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! bash scripts/gen_placement.sh --stdout > "$TMP" 2>/dev/null; then
    echo "check_placement_status: could not regenerate the placement index" >&2
    exit 1
fi

if diff -q "$YAML" "$TMP" >/dev/null 2>&1; then
    echo "    placement_drift: $(grep -c '^  "' "$YAML") vars match the running runtime"
    exit 0
fi

echo "check_placement_status: $YAML disagrees with the code." >&2
echo "  A var moved between Zig and .clj, or was added / removed, without the" >&2
echo "  index following. Regenerate in the same commit as the change:" >&2
echo "      bash scripts/gen_placement.sh" >&2
echo "" >&2
diff "$YAML" "$TMP" | sed -n 40p >&2
exit 1
