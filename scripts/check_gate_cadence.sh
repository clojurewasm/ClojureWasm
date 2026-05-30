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

# --- 3. not fresh: apply the cadence rule -----------------------------------
if [[ "$risky" -eq 1 ]]; then
  cat >&2 <<EOF
✗ commit blocked by scripts/check_gate_cadence.sh

This is a SHARED-CODE change ($risky_reason). Such changes carry
regression + dual-backend-parity risk, so the policy requires a fresh
full gate every time — no batching.

  Run:  bash test/run_all.sh
  then re-commit (the gate records .dev/.gate_pass for the verified state).

Policy: $RULE
EOF
  exit 2
fi

# Additive + not fresh → consume one batch slot.
count="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
[[ "$count" =~ ^[0-9]+$ ]] || count=0
count=$((count + 1))

if [[ "$count" -gt "$GATE_MAX_BATCH" ]]; then
  cat >&2 <<EOF
✗ commit blocked by scripts/check_gate_cadence.sh

$GATE_MAX_BATCH additive source commits have accumulated since the last
full gate. Batch limit reached — run a full gate before continuing:

  Run:  bash test/run_all.sh
  then re-commit.

Policy: $RULE (additive coverage batches up to $GATE_MAX_BATCH per gate;
shared-code changes gate every time).
EOF
  exit 2
fi

echo "$count" > "$COUNT_FILE"
echo "[gate_cadence] additive source commit ${count}/${GATE_MAX_BATCH} since last full gate — ok (run \`bash test/run_all.sh\` to reset)"
exit 0
