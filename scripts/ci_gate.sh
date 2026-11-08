#!/usr/bin/env bash
# scripts/ci_gate.sh — single source of truth for the HOST-LOCAL verification
# gate. CI (.github/workflows/ci.yml, once per matrix OS) and the local
# maintainer flow (scripts/run_gate.sh) run the SAME thing, so "the gate is
# green" means one run wherever it is said. It checks the CURRENT host only;
# multi-host fan-out is the caller's job (the CI matrix /
# scripts/run_remote_ubuntu.sh's SSH leg).
#
# ONE configuration, no tiers (2026-08-12). This script used to branch on
# CLJW_CI_FULL (PR → smoke, everything else → full) and CLJW_CI_PARITY (nightly
# → an extra tree_walk sweep of corpus + every e2e). Both branches are gone.
#
# Why: every tier was a place where "green" meant something different. The
# nightly-only tree_walk sweep proved the point on its last run — it failed on a
# 5-second wall-clock bound for an nREPL port file, in a configuration nothing
# else ran, on a loaded shared runner. Measured locally on the same tree_walk
# build, that bind takes 0.08-0.14 s. So the one thing the extra tier ever
# reported was a fact about the runner. Meanwhile the coverage people actually
# rely on from it — the F-012 dual-backend diff oracle — is NOT lost: it runs in
# `zig build test` on BOTH backends (zig_build_test_vm + zig_build_test_tree_walk)
# in every gate, every time. Only the e2e SHELL suite on the non-default backend
# is gone, and scripts/check_vm_parity.sh still runs it on demand.
#
# The local smoke tier (ADR-0107) is unaffected: it is a per-commit tool
# (`test/run_all.sh --smoke <step>`), not a CI tier.
#
# --serial-e2e (not the -P8 parallel default) is deliberate: the parallel path
# can flake the D-418/D-258 agent send/await load-race under scheduler pressure,
# which is exactly what a shared CI runner provides. Serial is the authoritative
# full-gate mode. scripts/check_gate_parity.sh enforces that this script and
# run_gate.sh keep running the identical configuration.
#
# The gate has no external runtime dependency beyond Zig 0.16.0 and python3
# (one nREPL e2e uses a small python client); every Wasm fixture is a committed
# .wasm, and the diff oracle is Zig-native (no JVM Clojure oracle in the gate).
# The Zig package + build cache is preserved across CI runs (see ci.yml), so a
# warm run rebuilds only what changed rather than cold ReleaseSafe builds.
#
# Every unit reaches the suite through test/cljw-test, the one entry point.
# What `full` runs is a row in test/units.list, not a string repeated here and
# in run_gate.sh; check_gate_parity.sh resolves the row and compares.
#
# Usage:
#   bash scripts/ci_gate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[ci_gate] host: $(uname -s) — zig $(zig version)"

# fmt first and separately: it is seconds, and a non-canonical file should kill
# the run before a 15-minute gate, not after it.
echo "[ci_gate] (1/2) fmt"
bash test/cljw-test --only fmt

echo "[ci_gate] (2/2) full gate"
bash test/cljw-test --only full

echo "[ci_gate] OK ($(uname -s))"
