#!/usr/bin/env bash
# test/e2e/phase14_map_string_keys.sh
#
# D-151 cycle 1 — map lookup keys non-interned STRING keys by value
# (byte-equality), not by identity. `keyEqValue` in runtime/equal.zig,
# routed from map.zig + transient_array_map.zig keyEq. array_map only
# (≤8 entries; the HAMT path is D-045-deferred so >8 raises explicitly).
#
# Keys by `=` semantics (category-based: `{1 :a}` vs `1.0` → nil),
# matching JVM. Also unblocks `:strs` map-destructuring (D-076).

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

assert_eq 'get_string_key'   "$("$BIN" -e '(get {"x" 5} "x")')"                 '5'
assert_eq 'contains_string'  "$("$BIN" -e '(contains? {"x" 5} "x")')"           'true'
assert_eq 'get_string_miss'  "$("$BIN" -e '(get {"x" 5} "y")')"                 'nil'
assert_eq 'assoc_replace'    "$("$BIN" -e '(get (assoc {"k" 1} "k" 9) "k")')"   '9'
assert_eq 'multi_string_key' "$("$BIN" -e '(get {"a" 1 "b" 2 "c" 3} "b")')"     '2'
# `=` keys by value (category-based): int key ≠ float key, matching JVM.
assert_eq 'cat_int_float'    "$("$BIN" -e '(get {1 :a} 1.0)')"                   'nil'
assert_eq 'int_key_ok'       "$("$BIN" -e '(get {1 :a} 1)')"                     ':a'
assert_eq 'kw_key_ok'        "$("$BIN" -e '(get {:a 1} :a)')"                    '1'
# structural map = over string keys (mapEqual now value-compares keys).
assert_eq 'map_eq_strkeys'   "$("$BIN" -e '(= {"x" 1 "y" 2} {"y" 2 "x" 1})')"   'true'
# cross-feature: `:strs` destructuring (D-076) now functions on string keys.
assert_eq 'strs_destructure' "$("$BIN" -e '(let [{:strs [name]} {"name" "bob"}] name)')" '"bob"'

echo "OK — phase14_map_string_keys smoke (10 cases) green"
