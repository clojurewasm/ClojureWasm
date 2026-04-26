#!/usr/bin/env bash
# test/e2e/phase2_exit.sh
#
# Pin Phase-2's exit criteria as an end-to-end gate. The §9 phase
# tracker promises:
#
#   (let [x 1] (+ x 2))         → 3
#   ((fn* [x] (+ x 1)) 41)      → 42
#
# Phase 2 has no `let` macro yet (macros land in Phase 3+), so the
# first criterion uses `let*` (which `let` macroexpands to in
# Clojure JVM). Once Phase 3 lands a `let` macro, swap the call.
#
# Each case asserts both stdout content and a clean (0) exit; a
# stderr leak from the CLI's analyse / eval error path also fails
# the case.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"

echo "==> Building (Debug)"
zig build >/dev/null

if [[ ! -x "$BIN" ]]; then
    echo "✗ binary missing: $BIN" >&2
    exit 1
fi

run_case() {
    local label="$1"
    local expr="$2"
    local want="$3"
    local got
    got=$("$BIN" -e "$expr" 2>&1) || {
        echo "✗ $label: cljw exited non-zero" >&2
        echo "  output: $got" >&2
        exit 1
    }
    if [[ "$got" != "$want" ]]; then
        echo "✗ $label" >&2
        echo "  expr: $expr" >&2
        echo "  want: $want" >&2
        echo "  got:  $got" >&2
        exit 1
    fi
    echo "    ✓ $label"
}

echo "==> Phase-2 exit criteria"
run_case "(+ 1 2)"                "(+ 1 2)"               "3"
run_case "(let* [x 1] (+ x 2))"   "(let* [x 1] (+ x 2))"  "3"
run_case "((fn* [x] (+ x 1)) 41)" "((fn* [x] (+ x 1)) 41)" "42"

echo
echo "Phase-2 exit-criterion e2e: all green."
