#!/usr/bin/env bash
# test/e2e/phase14_opaque_host_class.sh
#
# ADR-0109 (D-293) — recognised OPAQUE host classes resolve as class VALUES.
# A JVM numeric class cljw COLLAPSES away (F-005): java.math.BigInteger→BigInt,
# Integer/Short/Byte/Float→Long/Double. cljw has no values of these types, so as
# class VALUES they are distinct-from-everything: `(= (type x) Integer)` and
# `(instance? Integer x)` are uniformly false (clj-faithful — a cljw int IS a
# Long), and `(extend-type Integer …)` is a LOAD-ONLY NO-OP (no cljw value can
# dispatch it — exactly as clj, where extending a never-instantiated class is
# also dead). Found across the ladder (numeric-tower :98/:127).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# class value resolves (no name_error) and is distinct from every cljw type
assert_eq 'integer_resolves'   "$(last_line "$("$BIN" -e 'Integer' 2>&1)")" 'Integer'
assert_eq 'type5_ne_integer'   "$(last_line "$("$BIN" -e '(= (type 5) Integer)' 2>&1)")" 'false'
assert_eq 'type5_eq_long'      "$(last_line "$("$BIN" -e '(= (type 5) Long)' 2>&1)")" 'true'
assert_eq 'bigint_ne_bigintgr' "$(last_line "$("$BIN" -e '(= (type (bigint 5)) java.math.BigInteger)' 2>&1)")" 'false'
# instance? on an opaque class is uniformly false (clj-faithful), never an error
assert_eq 'inst_integer_false'  "$(last_line "$("$BIN" -e '(instance? Integer 5)' 2>&1)")" 'false'
assert_eq 'inst_bigintgr_false' "$(last_line "$("$BIN" -e '(instance? java.math.BigInteger (bigint 5))' 2>&1)")" 'false'
assert_eq 'inst_short_false'    "$(last_line "$("$BIN" -e '(instance? Short 5)' 2>&1)")" 'false'
# cljw-native types still match instance? (unchanged)
assert_eq 'inst_long_true'     "$(last_line "$("$BIN" -e '(instance? Long 5)' 2>&1)")" 'true'
assert_eq 'inst_string_true'   "$(last_line "$("$BIN" -e '(instance? String "x")' 2>&1)")" 'true'
# extend-type on an opaque class is a load-only no-op (no crash); a real (Long)
# extension on the same protocol still dispatches — the Integer impl is dead in
# BOTH cljw and clj (verified: (m 5) → :long, not :int)
assert_eq 'extend_opaque_noop_dispatch' "$(last_line "$("$BIN" -e '(do (defprotocol P (m [x])) (extend-type Integer P (m [_] :int)) (extend-type Long P (m [_] :long)) (m 5))' 2>&1)")" ':long'
# ADR-0109: java.lang.Object is the UNIVERSAL supertype (resolves as a value;
# (isa? <any> Object)→true; (instance? Object x)→true for non-nil; nil→false).
# Unblocks algo.generic's `(derive Object root-type)`.
assert_eq 'isa_long_object'    "$(last_line "$("$BIN" -e '(isa? Long Object)' 2>&1)")" 'true'
assert_eq 'isa_string_object'  "$(last_line "$("$BIN" -e '(isa? String Object)' 2>&1)")" 'true'
assert_eq 'inst_object_nonnil' "$(last_line "$("$BIN" -e '(instance? Object 5)' 2>&1)")" 'true'
assert_eq 'inst_object_nil'    "$(last_line "$("$BIN" -e '(instance? Object nil)' 2>&1)")" 'false'
assert_eq 'derive_object'      "$(last_line "$("$BIN" -e '(do (derive (quote ::x) Object) (isa? (quote ::x) Object))' 2>&1)")" 'true'

# a genuinely-unknown class name still raises (no silent default-shift)
if "$BIN" -e '(instance? TotallyFakeClass 5)' >/dev/null 2>&1; then
    fail "unknown_class_still_errors: expected non-zero exit"
fi
echo "PASS unknown_class_still_errors"
