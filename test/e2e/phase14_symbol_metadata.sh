#!/usr/bin/env bash
# test/e2e/phase14_symbol_metadata.sh — symbol value-metadata (D-304).
# `(with-meta sym m)` mints a fresh non-interned symbol carrying meta;
# `(meta sym)` reads it. Symbol identity is ns+name only — meta is NOT
# part of `=` / hash (oracle-verified against clj). Keyword still rejects
# meta (clj ClassCastException; cljw keeps its type error). SCOPE = symbol;
# var/atom/ns meta is D-239.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }
# meta read: nil on a bare symbol, the map on a with-meta'd one
assert_eq 'sym_meta_nil'  "$("$BIN" -e "(meta 'a)")"                       'nil'
assert_eq 'sym_with_meta' "$("$BIN" -e "(meta (with-meta 'a {:x 1}))")"    '{:x 1}'
assert_eq 'sym_meta_key'  "$("$BIN" -e "(:x (meta (with-meta 'a {:x 1})))")" '1'
# value preserved: name/ns slices shared from the interned base (cljw -e
# prints the returned String pr-quoted, like clj's pr).
assert_eq 'sym_keepval'   "$("$BIN" -e "(str (with-meta 'foo {:a 1}))")"   '"foo"'
assert_eq 'sym_keepname'  "$("$BIN" -e "(name (with-meta 'ns/foo {:a 1}))")" '"foo"'
assert_eq 'sym_keepns'    "$("$BIN" -e "(namespace (with-meta 'ns/foo {:a 1}))")" '"ns"'
# identity: meta is NOT part of `=` (oracle: true) nor hash; identical? is false
assert_eq 'sym_eq_ignores_meta'  "$("$BIN" -e "(= 'a (with-meta 'a {:x 1}))")"  'true'
assert_eq 'sym_eq_both_meta'      "$("$BIN" -e "(= (with-meta 'a {:x 1}) (with-meta 'a {:y 2}))")" 'true'
assert_eq 'sym_hash_ignores_meta' "$("$BIN" -e "(= (hash 'a) (hash (with-meta 'a {:x 1})))")" 'true'
assert_eq 'sym_not_identical'     "$("$BIN" -e "(identical? 'a (with-meta 'a {:x 1}))")" 'false'
# map-key consistency: a with-meta'd symbol finds the bare-symbol key
assert_eq 'sym_map_key' "$("$BIN" -e "(get {'a 1} (with-meta 'a {:x 1}))")" '1'
# vary-meta over a symbol
assert_eq 'sym_vary'    "$("$BIN" -e "(meta (vary-meta (with-meta 'a {:x 1}) assoc :y 2))")" '{:x 1, :y 2}'
assert_eq 'sym_vary_nil' "$("$BIN" -e "(meta (vary-meta 'a assoc :y 2))")" '{:y 2}'
# GC survival: the meta map is reachable only through the gc.alloc'd symbol,
# so its `.symbol` trace (ADR-0110 membrane flip) must mark it across the
# collections the inner allocations trigger.
assert_eq 'sym_meta_gc_survives' "$("$BIN" -e "(let [s (with-meta 'a {:x 1})] (dotimes [_ 50000] (vec (range 20))) (:x (meta s)))")" '1'
# keyword still rejects meta (clj ClassCastException; cljw type error)
assert_has 'kw_rejects' "$("$BIN" -e '(with-meta :a {:x 1})' 2>&1)" 'keyword'
echo "OK — phase14_symbol_metadata smoke (15 cases) green"
