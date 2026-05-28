#!/usr/bin/env bash
# test/e2e/phase14_range_indexed.sh
#
# Phase 14 §9.16 row 14.13 — D-134 eager-finite range + index fns:
# range (1-arg / 2-arg) / map-indexed / keep-indexed. Eager (DIVERGENCE:
# JVM returns lazy seqs; the infinite 0-arg (range) awaits the lazy-seq
# Layer-2 gap and is absent for now). Pattern A over a recursive helper /
# mapv / nth / count.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'range_n'      "$("$BIN" -e '(into [] (range 4))')"        '[0 1 2 3]'
assert_eq 'range_se'     "$("$BIN" -e '(into [] (range 2 5))')"      '[2 3 4]'
assert_eq 'range_zero'   "$("$BIN" -e '(into [] (range 0))')"        '[]'
assert_eq 'map_indexed'  "$("$BIN" -e '(into [] (map-indexed (fn* [i x] [i x]) [:a :b]))')" '[[0 :a] [1 :b]]'
assert_eq 'keep_indexed' "$("$BIN" -e '(into [] (keep-indexed (fn* [i x] (if (= 0 (rem i 2)) x nil)) [:a :b :c]))')" '[:a :c]'

echo "ALL phase14_range_indexed PASS"
