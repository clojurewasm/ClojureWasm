#!/usr/bin/env bash
# test/e2e/phase4_cli.sh
#
# ROADMAP §9.6 / 4.11 — run a curated subset of `phase3_cli` cases
# under both backends (`tree-walk` default, `vm` via `-Dbackend=vm`)
# and assert byte-for-byte equal outputs. This is the e2e half of
# the differential gate; the unit-level half lives in
# `src/eval/evaluator.zig` + `src/lang/diff_test.zig` (4.10).
#
# Strategy: build cljw twice (overwriting `zig-out/bin/cljw` between
# builds), capture all case outputs into a per-backend log, diff the
# two logs. Pass = identical. Fail = first divergence shown.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
WORK="$(mktemp -d -t cljw_phase4_cli.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "✗ $1" >&2
    exit 1
}

# --- Case set (subset of phase3_cli — pure expressions, deterministic) ---
# Each entry is `name|expr` (pipe delimiter so the expr can contain `=`).
CASES=(
    'arith|(+ 1 2)'
    'let_macro|(let [x 10] (+ x 32))'
    'fn_call|((fn* [x] (+ x 1)) 41)'
    'string_lit|"hello"'
    'quote_list|(quote (1 2 3))'
    'when_truthy|(when true 42)'
    'when_falsy|(when false 42)'
    'thread_first|(-> 1 (+ 2) (* 3))'
    'cond|(cond false 1 false 2 true 3 false 4)'
    'and|(and 1 2 3)'
    'or|(or false nil 7)'
    'if_let_truthy|(if-let [x 7] (+ x 1) 0)'
    'if_let_falsy|(if-let [x false] (+ x 1) 99)'
    'loop_recur|(loop* [i 0] (if (< i 3) (recur (+ i 1)) i))'
    'closure|((let* [x 10] (fn* [y] (+ x y))) 5)'
    # ADR-0130 op_add intrinsic: heap-valued + deopt traps. The output-string
    # diff (unlike the bit-compare unit oracle) validates op_add (vm) ≡ builtin
    # (tree-walk) for results that are NOT inline NaN-boxed Values:
    #   - i48 boundary → a heap-Long (must NOT become a float); both print same.
    #   - a shadowed + (a local) must NOT hit op_add → calls str → "ab".
    #   - alter-var-root on + deopts op_add → the redefined root is honoured (999).
    'add_i48_boundary|(+ 140737488355327 1)'
    'add_shadow|(let [+ str] (+ "a" "b"))'
    'add_deopt|(do (alter-var-root (var +) (fn* [_] (fn* [a b] 999))) (+ 1 2))'
)

run_cases() {
    local backend="$1"
    local out="$2"
    : > "$out"
    for entry in "${CASES[@]}"; do
        local name="${entry%%|*}"
        local expr="${entry#*|}"
        local got
        got="$("$BIN" -e "$expr" 2>&1)" || true
        printf '%s\t%s\n' "$name" "$got" >> "$out"
    done
}

echo "==> Building (tree-walk)"
zig build -Dbackend=tree_walk -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
[[ -x "$BIN" ]] || fail "tree-walk binary missing: $BIN"
TW_LOG="$WORK/tw.txt"
run_cases tree_walk "$TW_LOG"
echo "    ✓ tree-walk captured ${#CASES[@]} cases"

echo "==> Building (vm)"
zig build -Dbackend=vm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
[[ -x "$BIN" ]] || fail "vm binary missing: $BIN"
VM_LOG="$WORK/vm.txt"
run_cases vm "$VM_LOG"
echo "    ✓ vm captured ${#CASES[@]} cases"

echo "==> Diffing outputs"
if ! diff -u "$TW_LOG" "$VM_LOG" > "$WORK/diff.txt"; then
    echo "✗ tree-walk ≠ vm divergence detected:" >&2
    cat "$WORK/diff.txt" >&2
    exit 1
fi
echo "    ✓ all ${#CASES[@]} cases produce byte-identical output under both backends"

# Restore the DEFAULT build (vm, production — ADR-0070) for subsequent
# run_all.sh steps so the cached binary matches the post-build state callers
# expect. Bare `zig build` (no -Dbackend) follows build.zig's default, so this
# stays correct across a future default change.
zig build -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
