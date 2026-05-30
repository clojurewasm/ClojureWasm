#!/usr/bin/env bash
# scripts/gate_state_hash.sh
#
# Prints a stable fingerprint of the *source content* — every tracked or
# untracked (non-ignored) file under src/ + test/ + build.zig* — by hashing
# each file's path and bytes. Two consumers share it so they agree on "what
# state did the full gate verify":
#
#   - test/run_all.sh writes this hash to .dev/.gate_pass on a full-gate
#     PASS (the content the gate just proved green).
#   - scripts/check_gate_cadence.sh recomputes it at `git commit` time and
#     compares: equal ⇒ the gate verified exactly this commit's content.
#
# Hashing CONTENT (not a diff vs HEAD) makes the fingerprint independent of
# HEAD position and of staging — so it still matches after the working-tree
# edits are `git add`ed and even survives a `git add && git commit` batched
# into one shell command (where the index is empty when the hook fires).
# bench/ is excluded (the gate appends to bench/quick_baseline.txt — an
# artefact, not source).
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
{
  git ls-files -co --exclude-standard -- src test build.zig build.zig.zon 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r f; do
        [ -f "$f" ] || continue
        printf '%s\0' "$f"
        cat -- "$f"
      done
} | shasum | awk '{print $1}'
