#!/usr/bin/env bash
# scripts/check_placement_status.sh
#
# Audit + status-flip helper for placement.yaml.
#
# placement.yaml carries one row per Clojure-ns var with a status field:
#   - transient_zig         — currently Zig-leaf, awaiting Pattern A/B
#                              .clj migration
#   - ready_for_migration   — leaf + composition_deps available; can be
#                              migrated this cycle
#   - stable                — Pattern A/B `.clj` migration applied
#   - migrated              — historical migration record (= same as
#                              stable but recorded post-discharge)
#
# This script runs in two modes:
#
#   audit     (default)   — for each entry, verify recall_trigger
#                            predicates and propose status flips.
#                            Outputs to stdout; never edits the yaml.
#   --check               — exit 1 if any entry's status is logically
#                            inconsistent (= primitive Zig leaf absent
#                            but status: transient_zig). Used in CI.
#   --sweep               — produce a per-Phase migration shortlist:
#                            all `ready_for_migration` entries grouped
#                            by their target_loc / leaf_deps. Used at
#                            cycle planning.
#
# Discipline source: `private/notes/clj_vs_zig_split_proposal_v5.md`
# §15 + ROADMAP §9.8 + debt row D-062 (cluster) + placement.yaml
# schema doc. Cited by:
#   - v5 plan §15.x
#   - audit_scaffolding/CHECKS.md
#   - placement.yaml schema doc

set -u
set -o pipefail

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

YAML="placement.yaml"
MODE="audit"

case "${1:-}" in
  --check) MODE="check"; shift ;;
  --sweep) MODE="sweep"; shift ;;
  audit) MODE="audit"; shift ;;
esac

if [[ ! -f "$YAML" ]]; then
  echo "✗ placement.yaml not found at repo root" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "✗ yq required; install with brew install yq" >&2
  exit 1
fi

# --- helpers ------------------------------------------------------------------

count_status() {
  local status="$1"
  yq -r ".vars | to_entries | .[] | select(.value.status == \"$status\") | .key" "$YAML" 2>/dev/null | wc -l | tr -d ' '
}

list_status() {
  local status="$1"
  yq -r ".vars | to_entries | .[] | select(.value.status == \"$status\") | .key" "$YAML" 2>/dev/null
}

# --- audit mode ---------------------------------------------------------------

audit() {
  echo "=== placement.yaml status histogram ==="
  printf '%-25s %s\n' "transient_zig:"       "$(count_status transient_zig)"
  printf '%-25s %s\n' "ready_for_migration:" "$(count_status ready_for_migration)"
  printf '%-25s %s\n' "stable:"              "$(count_status stable)"
  printf '%-25s %s\n' "migrated:"            "$(count_status migrated)"
  echo ""
  echo "Total: $(yq -r '.vars | length' "$YAML")"

  echo ""
  echo "=== entries with recall_trigger predicate ==="
  yq -r '.vars | to_entries | .[] | select(.value.recall_trigger != null) | "  \(.key): \(.value.recall_trigger)"' "$YAML" 2>/dev/null \
    | sort -u | head -40 || true

  echo ""
  echo "=== ready_for_migration shortlist (= candidates for next .clj migration cycle) ==="
  list_status ready_for_migration | sed 's/^/  - /'

  echo ""
  echo "Notes:"
  echo "  - Phase 6.16.b-1/-2/-3 migrated 12 clojure.set vars (Group A+B+C). Per-var status flips happen at the discharging commit; if any entry below should be 'stable' or 'migrated', amend in the same cycle."
  echo "  - D-062 cluster row in .dev/debt.yaml tracks the overall transient_zig → migrated discharge."
}

# --- check mode ---------------------------------------------------------------

check_mode() {
  local fail=0

  # Schema sanity: each entry must have a status in the enum.
  # Using map(select(...)) + length avoids a yq quirk where the
  # equivalent `.[] | select(...)` form emits a spurious empty entry
  # on this particular yaml shape.
  local bad_count
  bad_count=$(yq -r '.vars | to_entries | map(select(.value.status == null or (.value.status != "transient_zig" and .value.status != "ready_for_migration" and .value.status != "stable" and .value.status != "migrated"))) | length' "$YAML" 2>/dev/null)
  if [[ "${bad_count:-0}" -gt 0 ]]; then
    echo "✗ placement.yaml: $bad_count entries with missing or invalid status" >&2
    yq -r '.vars | to_entries | map(select(.value.status == null or (.value.status != "transient_zig" and .value.status != "ready_for_migration" and .value.status != "stable" and .value.status != "migrated"))) | .[] | "  - \(.key): status=\(.value.status)"' "$YAML" 2>/dev/null >&2
    fail=1
  fi

  if [[ $fail -eq 0 ]]; then
    echo "OK placement.yaml schema clean ($(yq -r '.vars | length' "$YAML") entries)"
  fi
  return $fail
}

# --- sweep mode ---------------------------------------------------------------

sweep() {
  echo "# ready_for_migration shortlist by composition_deps"
  echo ""
  yq -r '.vars | to_entries | .[] | select(.value.status == "ready_for_migration") | "- \(.key) — leaf=\(.value.leaf_loc // "n/a") deps=\(.value.composition_deps // [] | join(","))"' "$YAML" 2>/dev/null
}

case "$MODE" in
  audit) audit ;;
  check) check_mode ;;
  sweep) sweep ;;
esac
