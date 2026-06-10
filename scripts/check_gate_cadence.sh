#!/usr/bin/env bash
# scripts/check_gate_cadence.sh
#
# PreToolUse hook on `git commit`. Mechanically enforces the gate-cadence
# policy (.claude/rules/gate_cadence.md) so it is law, not just prose:
#
#   - NON-SOURCE commit (docs / .dev / .claude / scripts only, no src|test|
#     build.zig*): exempt. Never blocked, never counted.
#   - ADDITIVE source commit (touches src/ or test/, pure insertion — no
#     existing line removed/modified, no build.zig*): may accumulate up to
#     GATE_MAX_BATCH (default 5) since the last full gate. The 6th blocks.
#   - RISKY source commit (build.zig* touched, OR an existing src/ or test/
#     line removed/modified): requires a fresh full gate EVERY time.
#
# "Fresh full gate" = test/run_all.sh wrote .dev/.gate_pass with a
# source-state hash (scripts/gate_state_hash.sh) equal to the about-to-be-
# committed state. A matching hash both authorises the commit and resets
# the additive counter. The empirical basis: on additive coverage the full
# gate caught 0 regressions across this session that the per-feature smoke
# (`zig build` + `cljw -e` + the single e2e) had not already caught, so the
# ~50s full gate is near-pure insurance there and batching is safe; shared-
# code edits are where the gate earns its cost (regression + diff-oracle).
#
# Fail-closed: a git/python error in the shared helpers exits non-zero.
set -euo pipefail
source "$(dirname "$0")/hook_lib.sh"

hook_read_command
hook_is_git_commit || exit 0
hook_cd_project_root

GATE_MAX_BATCH="${GATE_MAX_BATCH:-5}"
PASS_FILE=".dev/.gate_pass"
SMOKE_FILE=".dev/.smoke_pass"
COUNT_FILE=".dev/.gate_cadence"
RULE=".claude/rules/gate_cadence.md"

# --- 1. classify the working-tree change vs HEAD (staging-independent) ------
# Classify from `git diff HEAD` + an untracked listing, NOT `git diff
# --cached`. PreToolUse fires BEFORE the command runs, so a
# `git add … && git commit` batched into one shell command leaves the index
# empty at hook time — `--cached` would then see nothing and wrongly exempt
# the commit. `git diff HEAD` reflects the working tree regardless of whether
# `git add` has run yet; brand-new files (untracked) are picked up separately.
src_changed=0
risky=0
risky_reason=""

# Tracked changes vs HEAD (modifications + insertions). numstat columns:
# <added> <deleted> <path>; binary files render '-' (treated as risky).
while IFS=$'\t' read -r added deleted path; do
  [[ -z "${path:-}" ]] && continue
  case "$path" in
    build.zig|build.zig.zon)
      src_changed=1; risky=1; risky_reason="build.zig* modified" ;;
    src/*|test/*)
      src_changed=1
      if [[ "$deleted" == "-" ]] || { [[ "$deleted" =~ ^[0-9]+$ ]] && [[ "$deleted" -gt 0 ]]; }; then
        risky=1; risky_reason="existing lines modified/removed in $path"
      fi
      ;;
  esac
done < <(git diff HEAD --numstat -- src test build.zig build.zig.zon)

# Brand-new (untracked, non-ignored) src/ or test/ files = additive source.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in src/*|test/*) src_changed=1 ;; esac
done < <(git ls-files --others --exclude-standard -- src test)

# No source change → docs/scripts/config commit → exempt.
[[ "$src_changed" -eq 0 ]] && exit 0

# --- 2. gate freshness ------------------------------------------------------
now_hash="$(bash "$(dirname "$0")/gate_state_hash.sh")"
gated_hash="$(cat "$PASS_FILE" 2>/dev/null || echo '')"

if [[ -n "$gated_hash" && "$now_hash" == "$gated_hash" ]]; then
  # The full gate verified exactly this state → authorise + reset counter.
  echo 0 > "$COUNT_FILE"
  exit 0
fi

# --- 2b. smoke freshness (ADR-0107) -----------------------------------------
# A fresh `--smoke` (zig build test ×2 = the full dual-backend diff oracle + all
# unit, + lint + build_cljw + corpus + the changed e2e) authorises ANY source
# commit — risky or additive — because the F-012 correctness oracle ran in full.
# It consumes one batch slot; the ceiling forces a full gate (which also runs the
# 248-step e2e SHELL suite + perf that smoke skips). A full gate resets the count.
smoke_hash="$(cat "$SMOKE_FILE" 2>/dev/null || echo '')"
if [[ -n "$smoke_hash" && "$now_hash" == "$smoke_hash" ]]; then
  count="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  count=$((count + 1))
  if [[ "$count" -gt "$GATE_MAX_BATCH" ]]; then
    cat >&2 <<EOF
⚠ [gate_cadence] advisory (non-blocking since 2026-06-11): $GATE_MAX_BATCH+
smoke-authorized commits since the last full gate. Recommended to run a full gate
soon (catches any e2e-shell regression the smoke skips + resets the count):
  bash test/run_all.sh
Policy: $RULE (ADR-0107 two-tier gate; effort-goal, not a hard block).
EOF
  fi
  echo "$count" > "$COUNT_FILE"
  echo "[gate_cadence] smoke-authorized commit ${count}/${GATE_MAX_BATCH} since last full gate — ok (run \`bash test/run_all.sh\` to reset)"
  exit 0
fi

# --- 3. neither full-gate nor smoke fresh: apply the cadence rule -----------
if [[ "$risky" -eq 1 ]]; then
  cat >&2 <<EOF
⚠ [gate_cadence] advisory (non-blocking since 2026-06-11): shared-code change
($risky_reason) with no fresh smoke/gate fingerprint. Recommended:
  bash test/run_all.sh --smoke <changed-e2e-step>   # ~tens of seconds
The smoke cadence is now an effort-goal, not a hard block (user-directed).
Policy: $RULE
EOF
  exit 0
fi

# Additive + not fresh → consume one batch slot (rides without even a smoke; the
# new files cannot break existing behaviour, and the ceiling still forces a gate).
count="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
[[ "$count" =~ ^[0-9]+$ ]] || count=0
count=$((count + 1))

if [[ "$count" -gt "$GATE_MAX_BATCH" ]]; then
  cat >&2 <<EOF
⚠ [gate_cadence] advisory (non-blocking since 2026-06-11): $GATE_MAX_BATCH+
source commits since the last full gate. Recommended to run one soon:
  bash test/run_all.sh
Policy: $RULE (effort-goal, not a hard block).
EOF
fi

echo "$count" > "$COUNT_FILE"
echo "[gate_cadence] additive source commit ${count}/${GATE_MAX_BATCH} since last full gate — ok (run \`bash test/run_all.sh\` to reset)"
exit 0
