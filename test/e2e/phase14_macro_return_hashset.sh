#!/usr/bin/env bash
# test/e2e/phase14_macro_return_hashset.sh — a macro whose return form contains a
# >8-element set (whose backing map has promoted past the .array_map ceiling)
# re-analyses correctly. The analyzer's valueSetToForm decoded the backing map
# as an ArrayMap unconditionally, so a promoted set had a HashMap's fields read
# as `count` / `entries` and indexed off the end — a segfault (or, in a
# ReleaseSafe build, `index out of bounds: index 16, len 16`) with no diagnostic
# anywhere near the set. Twin of phase14_macro_return_hashmap.sh, which fixed
# exactly this for maps; both now route through the generic forEach path.
# Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

run() { "$BIN" - <<EOF 2>&1 | tail -1
$1
EOF
}

# The boundary: 8 elements is array-backed, 9 promotes. Both must survive the
# Value -> Form round-trip a macro expansion performs.
assert_eq 'macro-return-hashset-count' \
  "$(run '(defmacro mk [] (quote (count #{:a :b :c :d :e :f :g :h :i}))) (prn (mk))')" \
  '9'
assert_eq 'macro-return-hashset-contains' \
  "$(run '(defmacro mk [] (quote (contains? #{:a :b :c :d :e :f :g :h :i} :i))) (prn (mk))')" \
  'true'
# Well past the ceiling — the promoted representation, not just its first rung.
assert_eq 'macro-return-large-hashset' \
  "$(run '(defmacro mk [] (quote (count #{1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20}))) (prn (mk))')" \
  '20'
# The shape that surfaced it: a macro inlining its variant set into the expansion.
assert_eq 'macro-def-inlined-hashset' \
  "$(run '(defmacro mk [] (list (quote def) (quote S) #{:a :b :c :d :e :f :g :h :i})) (mk) (prn (count S))')" \
  '9'
# Syntax-quoted, with an unquote — the set is rebuilt during expansion.
assert_eq 'macro-return-sq-hashset' \
  "$(run '(defmacro mk [x] `(contains? #{:a :b :c :d :e :f :g :h ~x} :z)) (prn (mk :z))')" \
  'true'
# Nested: a promoted set inside a map value, and a promoted set inside a set.
assert_eq 'macro-return-nested-hashset' \
  "$(run '(defmacro mk [] (quote (count (:k {:k #{1 2 3 4 5 6 7 8 9 10}})))) (prn (mk))')" \
  '10'
assert_eq 'macro-return-set-of-sets' \
  "$(run '(defmacro mk [] (quote (count (first #{#{1 2 3 4 5 6 7 8 9}})))) (prn (mk))')" \
  '9'
# Regressions: the array-backed rungs must keep working.
assert_eq 'macro-return-arrayset' \
  "$(run '(defmacro mk [] (quote (count #{:a :b :c :d :e :f :g :h}))) (prn (mk))')" \
  '8'
assert_eq 'macro-return-empty-set' \
  "$(run '(defmacro mk [] (quote (count #{}))) (prn (mk))')" \
  '0'
