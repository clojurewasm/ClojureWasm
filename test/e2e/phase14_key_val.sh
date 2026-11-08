#!/usr/bin/env bash
# test/e2e/phase14_key_val.sh — (key e) / (val e) over map entries. cljw's map
# entries are a DISTINCT type (`(map-entry? (first {:a 1}))` → true), so key/val
# require a real entry and THROW (catchably, no panic) on a plain vector / nil /
# list, matching clj — a plain vector is not a java.util.Map$Entry. The old
# positional leniency (`(key [:k :v])` → :k) was a vestige of the earlier
# "entries = 2-vectors" representation and is removed (clj parity, F-011).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# key/val on a real map entry (from seq-ing a map) work.
assert_eq 'key'        "$("$BIN" -e '(key (first {:a 1}))')"   ':a'
assert_eq 'val'        "$("$BIN" -e '(val (first {:a 1}))')"   '1'
assert_eq 'map_key'    "$("$BIN" -e '(map key {:a 1 :b 2})')"  '(:a :b)'
assert_eq 'map_val'    "$("$BIN" -e '(map val {:a 1 :b 2})')"  '(1 2)'
assert_eq 'reduce_val' "$("$BIN" -e '(reduce (fn [acc e] (+ acc (val e))) 0 {:a 1 :b 2})')" '3'
# clj parity: a non-entry throws a CATCHABLE error (exit≠0, never a panic). The
# `if out=$(...)` form keeps a non-zero exit from tripping set -e.
assert_throws() {
    local n="$1" out
    if out="$("$BIN" -e "$2" 2>&1)"; then fail "$n: expected throw, got '$out'"; fi
    grep -qiE 'panic|reached unreachable' <<<"$out" && fail "$n: PANICKED -> $out"
    echo "PASS $n -> throws (catchable)"
}
assert_throws 'key_plain_vector' '(key [:k :v])'
assert_throws 'val_plain_vector' '(val [:k :v])'
assert_throws 'key_nil'          '(key nil)'
assert_throws 'val_nil'          '(val nil)'
assert_throws 'key_list'         '(key (quote (1 2)))'
assert_throws 'val_list'         '(val (quote (1 2)))'
echo "OK — phase14_key_val smoke (11 cases) green"
