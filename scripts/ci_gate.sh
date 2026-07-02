#!/usr/bin/env bash
# scripts/ci_gate.sh — single source of truth for the HOST-LOCAL verification
# gate. Both CI (.github/workflows/ci.yml, once per matrix OS) and the local
# maintainer flow run this exact script, so CI can never verify LESS than the
# per-host gate. It checks the CURRENT host only; multi-host fan-out is the
# caller's job (the CI matrix / scripts/run_remote_ubuntu.sh's SSH leg).
#
# Two tiers, mirroring the local ADR-0107 discipline (smoke per commit, full
# batched) so CI is not wasteful on routine events:
#   CLJW_CI_FULL=1  → FULL gate: `zig build test` x2 (the F-012 dual-backend diff
#                     oracle + every unit), zlinter, a ReleaseSafe build_cljw,
#                     zone_check, corpus_regression, AND every e2e step
#                     (test/run_all.sh --serial-e2e). Set on nightly schedule + dispatch.
#   CLJW_CI_FULL=0  → fast CORE: the same correctness core WITHOUT the ~248 e2e
#                     shell steps (test/run_all.sh --smoke). Set on push-to-main / PR.
# Both tiers run `zig fmt --check src/` first.
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
#   bash scripts/ci_gate.sh                 # fast core (CLJW_CI_FULL unset → 0)
#   CLJW_CI_FULL=1 bash scripts/ci_gate.sh  # full gate
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[ci_gate] host: $(uname -s) — zig $(zig version) — full=${CLJW_CI_FULL:-0}"

echo "[ci_gate] (1/2) zig fmt --check src/"
zig fmt --check src/

if [ "${CLJW_CI_FULL:-0}" = "1" ]; then
    echo "[ci_gate] (2/2) FULL gate: test/run_all.sh --serial-e2e"
    bash test/run_all.sh --serial-e2e
else
    echo "[ci_gate] (2/2) fast CORE: test/run_all.sh --smoke"
    bash test/run_all.sh --smoke
fi

echo "[ci_gate] OK ($(uname -s), full=${CLJW_CI_FULL:-0})"
