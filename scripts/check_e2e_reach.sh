#!/usr/bin/env bash
# scripts/check_e2e_reach.sh — e2e ORPHAN guard (coverage-lie prevention).
#
# An e2e script under test/e2e/ that is NOT referenced in test/run_all.sh
# never runs in the gate — so it gives FALSE confidence (the file exists, looks
# like coverage, but gates nothing). This is the e2e sibling of
# check_test_reach.sh (which guards Zig `test {}` orphans). It surfaced
# 2026-06-02 when 5 newly-authored phase14 e2e + the pending phase14_eval were
# all unreferenced (D-196 / D-197 investigation).
#
# Fails if any test/e2e/*.sh is not referenced by name in run_all.sh, except
# the explicit ALLOWLIST (e2e for not-yet-implemented features, intentionally
# parked until the feature lands — each MUST cite a debt row here).
#
# Usage: bash scripts/check_e2e_reach.sh [--gate]   # --gate => exit 1 on orphan

set -uo pipefail
cd "$(dirname "$0")/.."

# Intentionally-not-gated e2e (feature pending). Format: "<basename> # D-NNN why".
ALLOWLIST=(
    "phase16_wasm_ffi.sh # D-259 opt-in: builds -Dwasm (resolves zwasm via the relative-path build.zig.zon), so it is intentionally NOT in the default per-commit gate (F-001: the default gate never resolves zwasm). Run explicitly or in a wasm-aware gate."
    "phase16_wasm_run.sh # ADR-0124 opt-in: builds -Dwasm (resolves zwasm), so intentionally NOT in the default per-commit gate (F-001). Exercises (wasm/run …) WASI command execution. Run explicitly or in a wasm-aware gate."
)

allowed() {
    local b="$1"
    [ "${#ALLOWLIST[@]}" -eq 0 ] && return 1
    for a in "${ALLOWLIST[@]}"; do
        [ "${a%% *}" = "$b" ] && return 0
    done
    return 1
}

runner="test/run_all.sh"
# The subject is what the REPOSITORY gates, so enumerate INDEXED e2e (tracked
# or staged) rather than everything on disk: an untracked script is not
# coverage anyone else can run, gates nothing in CI, and — in a checkout shared
# by several sessions — turns one session's in-flight file into a red step on
# every other session's gate run, which is how a real failure gets waved
# through. `git add` is the moment a script becomes the repo's claim, and that
# is the moment this guard starts holding it. Falls back to the on-disk glob
# outside a git worktree (tarball / vendored checkout).
list_e2e() {
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files --cached -- 'test/e2e/*.sh'
    else
        ls test/e2e/*.sh 2>/dev/null
    fi
}

orphans=0
for f in $(list_e2e); do
    b="$(basename "$f")"
    if grep -q -- "$b" "$runner"; then continue; fi
    if allowed "$b"; then
        echo "  allowed (pending): $b"
        continue
    fi
    echo "  ORPHAN (not in $runner): $b"
    orphans=$((orphans + 1))
done

if [ "$orphans" -gt 0 ]; then
    echo "check_e2e_reach: $orphans orphaned e2e — add to $runner or ALLOWLIST with a debt ref"
    [ "${1:-}" = "--gate" ] && exit 1
    exit 0
fi
echo "check_e2e_reach: all e2e referenced in $runner (or allowlisted)"
exit 0
