#!/usr/bin/env bash
# test/e2e/phase14_arrays.sh
#
# ADR-0105 / D-287 — Java arrays. Type-erased uniform []Value over
# rt/__array-make + aget/aset/alength/aclone; the clojure.core surface
# (object-array / int-array / byte-array / make-array / to-array / aset-* /
# amap / areduce) composed in core.clj. Per-constructor init defaults +
# byte/short/char wrap give clj-faithful VALUES (F-011); element type erased
# (AD-019); identity equality; simple class name (AD-003).

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

run() { "$BIN" -e "$1" 2>/dev/null; }

# --- core aget/aset/alength/aclone ---
assert_eq 'aset_aget' "$(run '(let [a (object-array 3)] (aset a 1 :x) (aget a 1))')" ':x'
assert_eq 'alength'   "$(run '(alength (object-array 4))')" '4'
assert_eq 'aclone_independent' "$(run '(let [a (int-array [7 7]) b (aclone a)] (aset a 0 9) [(aget a 0) (aget b 0)])')" '[9 7]'

# --- per-constructor init defaults (F-011) ---
assert_eq 'object_array_nil'  "$(run '(vec (object-array 2))')"  '[nil nil]'
assert_eq 'int_array_zero'    "$(run '(vec (int-array 2))')"     '[0 0]'
assert_eq 'double_array_zero' "$(run '(vec (double-array 2))')"  '[0.0 0.0]'
assert_eq 'boolean_array_false' "$(run '(vec (boolean-array 2))')" '[false false]'

# --- byte wrap (AD pin — F-011, oracle: (byte-array [1 2 300]) => [1 2 44]) ---
assert_eq 'byte_array_wrap' "$(run '(vec (byte-array [1 2 300]))')" '[1 2 44]'
assert_eq 'aset_byte_wrap'  "$(run '(let [a (byte-array 1)] (aset-byte a 0 200) (aget a 0))')" '-56'

# --- constructor from a seq ---
assert_eq 'object_array_from_seq' "$(run '(vec (object-array [:a :b :c]))')" '[:a :b :c]'

# --- seqable / indexed / reduce ---
assert_eq 'seq_over_array'    "$(run '(vec (seq (int-array [1 2 3])))')" '[1 2 3]'
assert_eq 'count_array'       "$(run '(count (int-array [1 2 3]))')" '3'
assert_eq 'map_over_array'    "$(run '(vec (map inc (int-array [1 2 3])))')" '[2 3 4]'
assert_eq 'reduce_over_array' "$(run '(reduce + (int-array [1 2 3]))')" '6'
assert_eq 'nth_array'         "$(run '(nth (object-array [:a :b]) 1)')" ':b'
assert_eq 'nth_array_default' "$(run '(nth (object-array [:a]) 9 :none)')" ':none'

# --- make-array (multi-dim) ---
assert_eq 'make_array_1d' "$(run '(alength (make-array nil 5))')" '5'
assert_eq 'make_array_2d' "$(run '(let [m (make-array nil 2 3)] [(alength m) (alength (aget m 0))])')" '[2 3]'

# --- amap / areduce ---
assert_eq 'amap'    "$(run '(vec (amap (int-array [1 2 3]) i r (* 2 (aget r i))))')" '[2 4 6]'
assert_eq 'areduce' "$(run '(areduce (int-array [1 2 3]) i r 0 (+ r (aget (int-array [1 2 3]) i)))')" '6'

# --- to-array / into-array ---
assert_eq 'to_array'   "$(run '(vec (to-array [1 2 3]))')" '[1 2 3]'
assert_eq 'into_array' "$(run '(vec (into-array [4 5]))')" '[4 5]'

# --- identity equality (AD pin — clj: distinct arrays are not =) ---
assert_eq 'array_identity_neq' "$(run '(= (object-array 1) (object-array 1))')" 'false'
assert_eq 'array_self_eq'      "$(run '(let [a (object-array 1)] (= a a))')" 'true'

# --- predicate + class (AD-003 simple name) ---
assert_eq 'array_pred'  "$(run '(array? (object-array 0))')" 'true'
assert_eq 'array_pred_neg' "$(run '(array? [1 2])')" 'false'
assert_eq 'array_class_simple' "$(run '(class (object-array 0))')" 'array'

# --- AD-019 pin: ^"[B" type hint is advisory; aset accepts any element ---
assert_eq 'type_hint_advisory' "$(run '(let [^"[B" b (byte-array 1)] (aset b 0 65) (aget b 0))')" '65'
