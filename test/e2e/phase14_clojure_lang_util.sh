#!/usr/bin/env bash
# test/e2e/phase14_clojure_lang_util.sh
#
# clojure.lang.Util static surface (ADR-0108) — the first member of the third
# host-surface tree runtime/clojure/lang/. Real pure-Clojure libs drop to these
# runtime statics (~95 corpus call sites; data.finger-tree's Util/hash). Each
# value-based static is oracle-verified vs clj; hash/hasheq return cljw-native
# values (AD-009 — intra-cljw consistency only).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# equiv = Clojure `=` (category-strict): (equiv 1 1.0) false, (equiv 1 1) true
assert_eq 'equiv_cross_cat' "$(last_line "$("$BIN" -e '(clojure.lang.Util/equiv 1 1.0)')")" 'false'
assert_eq 'equiv_same'      "$(last_line "$("$BIN" -e '(clojure.lang.Util/equiv 1 1)')")" 'true'
# equals = Java .equals (type-sensitive): (equals 1 1N) false, (equals "a" "a") true
assert_eq 'equals_type_sensitive' "$(last_line "$("$BIN" -e '(clojure.lang.Util/equals 1 1N)')")" 'false'
assert_eq 'equals_same_type'      "$(last_line "$("$BIN" -e '(clojure.lang.Util/equals "a" "a")')")" 'true'
# identical = reference identity
assert_eq 'identical_small_int' "$(last_line "$("$BIN" -e '(clojure.lang.Util/identical 1 1)')")" 'true'
# isInteger: Long + BigInt true
assert_eq 'isInteger_long'  "$(last_line "$("$BIN" -e '(clojure.lang.Util/isInteger 5)')")" 'true'
assert_eq 'isInteger_bigint' "$(last_line "$("$BIN" -e '(clojure.lang.Util/isInteger 5N)')")" 'true'
assert_eq 'isInteger_double' "$(last_line "$("$BIN" -e '(clojure.lang.Util/isInteger 1.5)')")" 'false'
# compare: three-way (-1/0/1), nil least
assert_eq 'compare_nil_least' "$(last_line "$("$BIN" -e '(clojure.lang.Util/compare nil 1)')")" '-1'
assert_eq 'compare_gt'        "$(last_line "$("$BIN" -e '(clojure.lang.Util/compare 3 2)')")" '1'
assert_eq 'compare_eq'        "$(last_line "$("$BIN" -e '(clojure.lang.Util/compare 2 2)')")" '0'
# pcequiv = `=`
assert_eq 'pcequiv' "$(last_line "$("$BIN" -e '(clojure.lang.Util/pcequiv [1 2] [1 2])')")" 'true'
# isPrimitive: cljw has no primitive classes → always false
assert_eq 'isPrimitive' "$(last_line "$("$BIN" -e '(clojure.lang.Util/isPrimitive Long)')")" 'false'
# classOf (D-303): matches (class x) exactly; (classOf nil) → nil
assert_eq 'classOf_eq_class' "$(last_line "$("$BIN" -e '(= (clojure.lang.Util/classOf 5) (class 5))')")" 'true'
assert_eq 'classOf_nil'      "$(last_line "$("$BIN" -e '(clojure.lang.Util/classOf nil)')")" 'nil'
# hash: works (was the data.finger-tree blocker) + intra-cljw consistency (AD-009):
#   Util/hash delegates to cljw value-hash, so it agrees with core `hash`.
assert_eq 'hash_intra_consistent' "$(last_line "$("$BIN" -e '(= (clojure.lang.Util/hash :a) (hash :a))')")" 'true'
assert_eq 'hasheq_intra_consistent' "$(last_line "$("$BIN" -e '(= (clojure.lang.Util/hasheq [1 2]) (hash [1 2]))')")" 'true'
