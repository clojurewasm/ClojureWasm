#!/usr/bin/env bash
# test/e2e/phase14_seq_core_batch.sh
#
# D-134 missing-core batch — split-with, take-nth, list*. All Pattern A
# `.clj`. (split-with returns lazy-seqs; realized via `mapv vec` for the
# assertion since nested lazy-seqs print as #<lazy_seq> per ADR-0054
# cycle-2 "top-level only" — a documented printer limitation, not a bug.)

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'split_with'   "$("$BIN" -e '(mapv vec (split-with (fn* [x] (< x 3)) [1 2 3 4 1]))')" '[[1 2] [3 4 1]]'
assert_eq 'split_all'    "$("$BIN" -e '(mapv vec (split-with (fn* [x] (< x 9)) [1 2]))')"       '[[1 2] []]'
assert_eq 'take_nth_2'   "$("$BIN" -e '(take-nth 2 [1 2 3 4 5 6])')"   '(1 3 5)'
assert_eq 'take_nth_3'   "$("$BIN" -e '(take-nth 3 [0 1 2 3 4 5 6])')" '(0 3 6)'
assert_eq 'list_star_2'  "$("$BIN" -e '(list* 1 [2 3 4])')"           '(1 2 3 4)'
assert_eq 'list_star_3'  "$("$BIN" -e '(list* 1 2 [3 4])')"           '(1 2 3 4)'
assert_eq 'list_star_1'  "$("$BIN" -e '(list* [1 2 3])')"            '(1 2 3)'
assert_eq 'list_star_quote' "$("$BIN" -e "(list* 'a '(b c))")"        '(a b c)'

echo "OK — phase14_seq_core_batch smoke (8 cases) green"
