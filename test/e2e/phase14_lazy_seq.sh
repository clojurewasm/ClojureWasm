#!/usr/bin/env bash
# test/e2e/phase14_lazy_seq.sh
#
# Phase 14 §9.16 row 14.13.5 — lazy-seq Layer-2 cycle 1 (ADR-0054). Wire
# the lazy_seq PRODUCER: `lazy-seq` macro + `__lazy-seq-create` primitive
# (delay/future triad) + cons accepting an unforced lazy tail + `iterate`.
# `take` is already lazy-aware-bounded, so it realizes only N elements of
# an infinite lazy seq and returns a finite list (prints normally — the
# print-API rt/env threading is deferred to cycle 2 when a lazy seq is a
# top-level result).
#
# Proof: (take 5 (iterate inc 0)) → (0 1 2 3 4), without hanging.
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# The canonical Phase-6 exit criterion (never met until now):
assert_eq 'iterate_take'   "$("$BIN" -e '(take 5 (iterate inc 0))')"                   '(0 1 2 3 4)'
assert_eq 'iterate_vec'    "$("$BIN" -e '(into [] (take 5 (iterate inc 0)))')"          '[0 1 2 3 4]'
assert_eq 'iterate_mul'    "$("$BIN" -e '(into [] (take 4 (iterate (fn* [x] (* x 2)) 1)))')" '[1 2 4 8]'
# laziness: first of an infinite seq must not hang
assert_eq 'iterate_first'  "$("$BIN" -e '(first (iterate inc 0))')"                     '0'
# lazy-seq wrapping a finite tail realizes correctly
assert_eq 'lazy_seq_finite' "$("$BIN" -e '(into [] (take 3 (lazy-seq (cons 1 (cons 2 (cons 3 nil))))))')" '[1 2 3]'

echo "ALL phase14_lazy_seq PASS"
