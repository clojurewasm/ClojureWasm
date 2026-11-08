#!/usr/bin/env bash
# scripts/check_vm_parity.sh — NON-DEFAULT-backend e2e sweep (D-553; was the
# ADR-0070 / D-196 VM-parity probe).
#
# Builds cljw with `-Dbackend=tree_walk` (the F-012 differential-oracle
# backend; `vm` is the production default since ADR-0070 step 4) and runs the
# corpus + the FULL test/e2e suite against it — so an oracle-only e2e /
# rendering regression cannot hide behind the vm-default gate.
#
# Cadence: **ON-DEMAND ONLY — this is not wired into any gate** (2026-08-12).
# It used to run in the CI nightly (CLJW_CI_PARITY=1), which made CI verify
# something the local gate did not; `scripts/check_gate_parity.sh` now fails if
# it is put back into a launcher. What that tier reported on its last run was a
# 5-second wall-clock bound for an nREPL port file, failing on a loaded shared
# runner in a config nothing else ran — the same bind measures 0.08-0.14 s
# locally on this very build. What it never had to carry is the correctness
# parity people assume from its name: the F-012 dual-backend diff oracle runs in
# `zig build test` on BOTH backends in every gate. This sweep adds the e2e SHELL
# suite on the non-default backend — worth running by hand after touching
# backend-divergent code, not worth a second gate configuration.
# Runtime ≈ one serial e2e pass (~5 min).
#
# SKIPS lists e2e steps that intrinsically exercise the DEFAULT backend
# (AOT bytecode / build pipeline) and are meaningless or false-failing on
# tree-walk; each entry carries its reason. A newly-failing step NOT in
# SKIPS is a genuine tree-walk regression — fix it, don't add it here
# without a reason.
#
# HISTORY: the D-196 blocker era (VM gaps masked by the then-tree_walk
# default) closed 2026-06-02; build.zig's default flipped to vm. This script
# then idled as a corpus-only probe until the D-553 repurpose (2026-07-06).
#
# Restores the DEFAULT (vm ReleaseSafe wasm — the unified gate config)
# binary on exit.
# Usage: bash scripts/check_vm_parity.sh   # exit 0 = all green; N = N failing.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib_build_lock.sh"

# e2e basenames (minus .sh) that are DEFAULT-BACKEND-specific by design.
SKIPS=(
    # (populated empirically; empty = the whole suite is backend-neutral)
)

restore() { with_build_lock zig build -Dwasm -Doptimize=ReleaseSafe >/dev/null 2>&1 || true; }
trap restore EXIT

# Portable bounded run: GNU `timeout`, else macOS coreutils `gtimeout`, else
# unbounded. Hosted macOS runners ship NEITHER — a raw `timeout` there errors
# with "command not found" (exit 127), which this script would have misread as
# a tree-walk FAIL for every e2e (empty diff, since 127's text matches no
# FAIL/error). This is the same helper the e2e scripts + check_corpus_regression
# use; check_vm_parity was the last raw caller missed by commit 264804b7's sweep.
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

echo "check_vm_parity: building -Dbackend=tree_walk -Doptimize=ReleaseSafe…"
if ! with_build_lock zig build -Dwasm -Doptimize=ReleaseSafe -Dbackend=tree_walk >/tmp/vmp_build.txt 2>&1; then
    echo "check_vm_parity: tree-walk BUILD FAILED (see /tmp/vmp_build.txt)"; exit 1
fi
export CLJW_SKIP_BUILD=1

fails=0
if bb scripts/corpus_regression.clj >/tmp/vmp_corpus.txt 2>&1; then
    echo "  corpus                    : ok  ($(tail -1 /tmp/vmp_corpus.txt))"
else
    echo "  corpus                    : FAIL ($(tail -1 /tmp/vmp_corpus.txt))"; fails=$((fails + 1))
fi

is_skipped() {
    local n="$1"
    for s in "${SKIPS[@]:-}"; do [ "$s" = "$n" ] && return 0; done
    return 1
}

for t in test/e2e/*.sh; do
    name="$(basename "$t" .sh)"
    if is_skipped "$name"; then
        echo "  SKIP (default-backend)    : $name"
        continue
    fi
    if run_bounded 180 bash "$t" >/tmp/vmp_e2e.txt 2>&1; then
        : # green — stay quiet (the suite is ~250 steps)
    else
        echo "  FAIL on tree-walk         : $name  ($(grep -iE 'FAIL|error' /tmp/vmp_e2e.txt | sed -n 1p | cut -c1-100))"
        fails=$((fails + 1))
    fi
done

echo "check_vm_parity: $fails failing group(s) (corpus + full e2e) on -Dbackend=tree_walk"
exit "$fails"
