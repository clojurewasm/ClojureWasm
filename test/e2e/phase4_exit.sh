#!/usr/bin/env bash
# test/e2e/phase4_exit.sh
#
# ROADMAP §9.6 / 4.12 — Phase-4 exit smoke.
#
# `(defn f [x] (+ x 1)) (f 2)` evaluates to `3` under both backends.
# This pins the critical-path closure of Phase 4: the VM dispatch
# loop, compiler, dual-backend gate, and bootstrap macro expansion
# all collaborate to produce one observable round-trip.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
WORK="$(mktemp -d -t cljw_phase4_exit.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "✗ $1" >&2
    exit 1
}

PROGRAM=$(cat <<'EOF'
(defn f [x] (+ x 1))
(f 2)
EOF
)

run_smoke() {
    local backend="$1"
    local got
    got=$(printf '%s\n' "$PROGRAM" | "$BIN" - 2>&1) || fail "$backend: cljw non-zero exit (output: $got)"
    # printf appends a newline to PROGRAM; the printValue loop emits
    # `nil\n` for defn's result then `3\n` for (f 2). We assert the
    # final non-empty line is `3`.
    local last
    last=$(printf '%s\n' "$got" | tail -1)
    [[ "$last" == "3" ]] || fail "$backend: want last line '3', got '$last' (full output: $got)"
    echo "    ✓ $backend: (defn f ...) (f 2) → 3"
}

echo "==> Building (tree-walk)"
zig build -Dbackend=tree_walk -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
[[ -x "$BIN" ]] || fail "tree-walk binary missing"
run_smoke tree_walk

echo "==> Building (vm)"
zig build -Dbackend=vm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
[[ -x "$BIN" ]] || fail "vm binary missing"
run_smoke vm

# Restore the DEFAULT build (vm, production — ADR-0070) for subsequent steps.
# Bare `zig build` follows build.zig's default (flip-agnostic).
zig build -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
