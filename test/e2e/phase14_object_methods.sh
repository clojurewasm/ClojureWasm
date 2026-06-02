#!/usr/bin/env bash
# test/e2e/phase14_object_methods.sh
#
# D-207 / clj-parity C3: universal java.lang.Object instance methods via a
# dispatch-level fallback (after a method-table miss) delegating to the cljw
# natives: .toString→str, .equals→=, .hashCode→hash, .getClass→class.
# Accepted divergences: .hashCode value = cljw hash (AD-009), .getClass prints
# the simple class name (AD-003); a method call on nil raises (clj NPEs).
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# .toString → str (bare top-level string/char, readable nested).
assert_eq 'ts_int'    "$("$BIN" -e '(.toString 42)')"            '"42"'
assert_eq 'ts_kw'     "$("$BIN" -e '(.toString :kw)')"           '":kw"'
assert_eq 'ts_vec'    "$("$BIN" -e '(.toString [1 2 3])')"       '"[1 2 3]"'
assert_eq 'ts_str'    "$("$BIN" -e '(.toString "hi")')"          '"hi"'
assert_eq 'ts_map'    "$("$BIN" -e '(.toString {:a 1})')"        '"{:a 1}"'

# .equals → = (incl. cross-type sequential; category-gated numerics).
assert_eq 'eq_t'      "$("$BIN" -e '(.equals 1 1)')"             'true'
assert_eq 'eq_numcat' "$("$BIN" -e '(.equals 1 1.0)')"          'false'
assert_eq 'eq_seq'    "$("$BIN" -e '(.equals [1 2] (list 1 2))')" 'true'
assert_eq 'eq_set'    "$("$BIN" -e '(.equals #{1 2} #{2 1})')"   'true'

# .hashCode → cljw hash (deterministic; value diverges from JVM — AD-009).
assert_eq 'hc_deleg'  "$("$BIN" -e '(= (.hashCode "abc") (hash "abc"))')" 'true'
assert_eq 'hc_int'    "$("$BIN" -e '(integer? (.hashCode 42))')" 'true'

# .getClass → class (prints the simple name per AD-003).
assert_eq 'gc_long'   "$("$BIN" -e '(str (.getClass 42))')"     '"Long"'
assert_eq 'gc_str'    "$("$BIN" -e '(str (.getClass "x"))')"    '"String"'

# nil receiver → error (clj NPEs; cljw raises, format differs per F-011).
if "$BIN" -e '(.toString nil)' >/dev/null 2>&1; then
  fail 'nil_recv: (.toString nil) should error, but it succeeded'
fi
echo 'PASS nil_recv -> errors'

# D-212: str / .toString of a BigInt / BigDecimal drop the N / M reader
# suffix (JVM BigInteger/BigDecimal.toString = plain digits); pr/prn KEEP it.
assert_eq 'str_bigint'   "$("$BIN" -e '(str 100N)')"        '"100"'
assert_eq 'str_bignt_n'  "$("$BIN" -e '(str -7N)')"         '"-7"'
assert_eq 'str_bigdec'   "$("$BIN" -e '(str 1.5M)')"        '"1.5"'
assert_eq 'str_bigdec_s' "$("$BIN" -e '(str 1.50M)')"       '"1.50"'
assert_eq 'str_bigdec_f' "$("$BIN" -e '(str 0.001M)')"      '"0.001"'
assert_eq 'ts_bigint'    "$("$BIN" -e '(.toString 100N)')"  '"100"'
assert_eq 'ts_bigdec'    "$("$BIN" -e '(.toString 1.5M)')"  '"1.5"'
assert_eq 'pr_bigint'    "$("$BIN" -e '(pr-str 100N)')"     '"100N"'
assert_eq 'pr_bigdec'    "$("$BIN" -e '(pr-str 1.5M)')"     '"1.5M"'
assert_eq 'str_nested'   "$("$BIN" -e '(str [100N 1.5M])')" '"[100N 1.5M]"'

echo "ALL phase14_object_methods PASS"
