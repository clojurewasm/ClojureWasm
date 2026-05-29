#!/usr/bin/env bash
# test/e2e/phase14_lazy_map.sh
#
# Phase 14 §9.16 row 14.13.5 — lazy-seq Layer-2 cycle 2 (ADR-0054).
# map/filter/keep/remove become lazy `.clj` (the -*-eager leaves are
# deleted); the print path realizes a top-level lazy result so the REPL
# renders `(2 3 4)`, not `#<lazy_seq>`. Laziness oracle uses `iterate`
# (cycle 1) as the infinite source.
#
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

# load-bearing: a lazy result prints as a realized seq, not #<lazy_seq>
assert_eq 'map_print'     "$("$BIN" -e '(map inc [1 2 3])')"                       '(2 3 4)'
assert_eq 'map_into'      "$("$BIN" -e '(into [] (map inc [1 2 3]))')"             '[2 3 4]'
assert_eq 'filter_into'   "$("$BIN" -e '(into [] (filter odd? [1 2 3 4]))')"       '[1 3]'
assert_eq 'keep_into'     "$("$BIN" -e '(into [] (keep (fn* [x] (if (odd? x) x nil)) [1 2 3 4]))')" '[1 3]'
assert_eq 'remove_into'   "$("$BIN" -e '(into [] (remove odd? [1 2 3 4]))')"       '[2 4]'
# laziness: map over an infinite iterate must not hang
assert_eq 'map_lazy_first' "$("$BIN" -e '(first (map inc (iterate inc 0)))')"      '1'
assert_eq 'map_lazy_take'  "$("$BIN" -e '(into [] (take 3 (map inc (iterate inc 0))))')" '[1 2 3]'
assert_eq 'map_empty'      "$("$BIN" -e '(into [] (map inc []))')"                 '[]'

echo "ALL phase14_lazy_map PASS"
