#!/usr/bin/env bash
# scripts/ci_gate.sh — single source of truth for the HOST-LOCAL verification
# gate. Both CI (.github/workflows/ci.yml, once per matrix OS) and the local
# maintainer flow run this exact script, so CI can never verify LESS than the
# per-host gate. It checks the CURRENT host only; multi-host fan-out is the
# caller's job (the CI matrix / scripts/run_remote_ubuntu.sh's SSH leg).
#
# Tiers, mirroring the local ADR-0107 discipline (smoke per commit locally, the
# full gate as the authoritative landing gate) so CI verifies what the
# maintainer's full gate does — never LESS:
#   CLJW_CI_FULL=1  → FULL gate == the LOCAL full gate: `zig build test` x2 (the
#                     F-012 dual-backend diff oracle + every unit), zlinter, a
#                     ReleaseSafe build_cljw, zone_check, corpus_regression, AND
#                     every e2e step (test/run_all.sh --serial-e2e). Set on
#                     push-to-main + nightly schedule + dispatch — every landed
#                     commit is fully e2e-verified, so a shared-code change that
#                     breaks an e2e step surfaces on the push, not a day later on
#                     the nightly (ADR-0107 revision 2026-07-21).
#   CLJW_CI_FULL=0  → fast CORE: the same correctness core WITHOUT the ~248 e2e
#                     shell steps (test/run_all.sh --smoke). Set on PR only, for
#                     fast iteration feedback; the PR's merge fires a push-to-main
#                     event that runs the FULL gate before it lands.
#   CLJW_CI_PARITY=1 → additionally the non-default-backend (tree_walk) sweep
#                     below. Heavier (a second ReleaseSafe rebuild), NOT part of
#                     the local full gate, so it stays nightly/dispatch-only — an
#                     EXTRA backstop, not a source of push-vs-local drift.
# Every tier runs `zig fmt --check src/` first.
#
# --serial-e2e (not the -P8 parallel default) is deliberate: the parallel path
# can flake the D-418/D-258 agent send/await load-race under scheduler pressure,
# which is exactly what a shared CI runner provides. Serial is the authoritative
# full-gate mode (see .dev/handover.md).
#
# The gate has no external runtime dependency beyond Zig 0.16.0 and python3
# (one nREPL e2e uses a small python client); every Wasm fixture is a committed
# .wasm, and the diff oracle is Zig-native (no JVM Clojure oracle in the gate).
# The Zig package + build cache is preserved across CI runs (see ci.yml), so a
# warm run rebuilds only what changed rather than three cold ReleaseSafe builds.
#
# Usage:
#   bash scripts/ci_gate.sh                                    # fast core (PR)
#   CLJW_CI_FULL=1 bash scripts/ci_gate.sh                     # full gate (push)
#   CLJW_CI_FULL=1 CLJW_CI_PARITY=1 bash scripts/ci_gate.sh    # full + backend sweep (nightly)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[ci_gate] host: $(uname -s) — zig $(zig version) — full=${CLJW_CI_FULL:-0}"

echo "[ci_gate] (1/2) zig fmt --check src/"
zig fmt --check src/

if [ "${CLJW_CI_FULL:-0}" = "1" ]; then
    echo "[ci_gate] FULL gate: test/run_all.sh --serial-e2e"
    bash test/run_all.sh --serial-e2e
else
    echo "[ci_gate] fast CORE: test/run_all.sh --smoke"
    bash test/run_all.sh --smoke
fi

# D-555: the NON-default-backend sweep — corpus + every e2e on the tree_walk
# (F-012 oracle) build, so an oracle-only regression (GC rooting,
# backend-divergent eval defects) cannot hide behind the vm-default gate. It
# rebuilds the binary twice (tree_walk, then the default restore) and is NOT
# part of the local full gate, so it stays nightly/dispatch-only (CLJW_CI_PARITY)
# — an extra backstop, not a per-push cost.
if [ "${CLJW_CI_PARITY:-0}" = "1" ]; then
    echo "[ci_gate] non-default-backend sweep: scripts/check_vm_parity.sh"
    bash scripts/check_vm_parity.sh
fi

echo "[ci_gate] OK ($(uname -s), full=${CLJW_CI_FULL:-0})"
