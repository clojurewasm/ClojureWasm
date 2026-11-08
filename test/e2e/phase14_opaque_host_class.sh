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
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

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
# ADR-0194: tools.reader names three JVM inner seq implementation classes.
# cljw has no values of these exact types, so their class values resolve but
# remain uniformly false and their extensions are dead-by-construction.
assert_eq 'inner_vector_seq_resolves' "$(last_line "$("$BIN" -e 'clojure.lang.PersistentVector$ChunkedSeq' 2>&1)")" 'clojure.lang.PersistentVector$ChunkedSeq'
assert_eq 'inner_array_map_seq_false' "$(last_line "$("$BIN" -e '(instance? clojure.lang.PersistentArrayMap$Seq (seq {:a 1}))' 2>&1)")" 'false'
assert_eq 'inner_hash_map_seq_false'  "$(last_line "$("$BIN" -e '(instance? clojure.lang.PersistentHashMap$NodeSeq (seq (hash-map :a 1)))' 2>&1)")" 'false'
# cljw-native types still match instance? (unchanged)
assert_eq 'inst_long_true'     "$(last_line "$("$BIN" -e '(instance? Long 5)' 2>&1)")" 'true'
assert_eq 'inst_string_true'   "$(last_line "$("$BIN" -e '(instance? String "x")' 2>&1)")" 'true'
# extend-type on an opaque class is a load-only no-op (no crash); a real (Long)
# extension on the same protocol still dispatches — the Integer impl is dead in
# BOTH cljw and clj (verified: (m 5) → :long, not :int)
assert_eq 'extend_opaque_noop_dispatch' "$(last_line "$("$BIN" -e '(do (defprotocol P (m [x])) (extend-type Integer P (m [_] :int)) (extend-type Long P (m [_] :long)) (m 5))' 2>&1)")" ':long'
assert_eq 'extend_inner_seq_noop' "$(last_line "$("$BIN" -e '(do (defprotocol InnerP (inner-m [x])) (extend-type clojure.lang.PersistentVector$ChunkedSeq InnerP (inner-m [_] :inner)) (extend-type Object InnerP (inner-m [_] :object)) (inner-m [1 2]))' 2>&1)")" ':object'
# ADR-0109: java.lang.Object is the UNIVERSAL supertype (resolves as a value;
# (isa? <any> Object)→true; (instance? Object x)→true for non-nil; nil→false).
# Explicit `(derive h Object root-type)` remains valid on the JVM.
assert_eq 'isa_long_object'    "$(last_line "$("$BIN" -e '(isa? Long Object)' 2>&1)")" 'true'
assert_eq 'isa_string_object'  "$(last_line "$("$BIN" -e '(isa? String Object)' 2>&1)")" 'true'
assert_eq 'inst_object_nonnil' "$(last_line "$("$BIN" -e '(instance? Object 5)' 2>&1)")" 'true'
assert_eq 'inst_object_nil'    "$(last_line "$("$BIN" -e '(instance? Object nil)' 2>&1)")" 'false'
# JVM rejects Class as the global derive parent; explicit hierarchies accept
# a Class child and a Named parent.
assert_eq 'derive_object_named_parent' "$(last_line "$("$BIN" -e '(isa? (derive (make-hierarchy) Object (quote root-type)) Object (quote root-type))' 2>&1)")" 'true'
assert_eq 'string_parents' "$(last_line "$("$BIN" -e '(and (contains? (parents String) Object) (= 6 (count (parents String))) (contains? (parents (make-hierarchy) String) Object))' 2>&1)")" 'true'
assert_eq 'string_ancestors' "$(last_line "$("$BIN" -e '(and (= 6 (count (ancestors String))) (contains? (ancestors (make-hierarchy) String) Object) (contains? (ancestors (derive (make-hierarchy) String (quote custom)) String) (quote custom)))' 2>&1)")" 'true'
assert_eq 'object_no_ancestors' "$(last_line "$("$BIN" -e '(ancestors Object)' 2>&1)")" 'nil'
for expr in '(derive (quote probe/x) String)' '(derive (make-hierarchy) (quote probe/x) String)' '(derive (make-hierarchy) (quote probe/x) Object)'; do
    if out=$($BIN -e "$expr" 2>&1); then fail "derive_class_parent: unexpectedly accepted $expr ($out)"; fi
    echo 'PASS derive_class_parent -> error'
done

# D-416: (Object.) constructs a fresh identity-unique value — the Clojure
# unique-sentinel idiom `(def notfound (Object.))` (data.finger-tree:556). The
# minted value reuses the SAME cached classDescriptor("Object") as the universal
# class value, so `(class (Object.))` == `Object` (JVM-faithful, no divergence).
assert_eq 'obj_ctor_identical_self'  "$(last_line "$("$BIN" -e '(let [o (Object.)] (identical? o o))' 2>&1)")" 'true'
assert_eq 'obj_ctor_distinct'        "$(last_line "$("$BIN" -e '(identical? (Object.) (Object.))' 2>&1)")" 'false'
assert_eq 'obj_ctor_not_equal'       "$(last_line "$("$BIN" -e '(= (Object.) (Object.))' 2>&1)")" 'false'
assert_eq 'obj_ctor_instance'        "$(last_line "$("$BIN" -e '(instance? Object (Object.))' 2>&1)")" 'true'
assert_eq 'obj_ctor_class_is_object' "$(last_line "$("$BIN" -e '(= (class (Object.)) Object)' 2>&1)")" 'true'
assert_eq 'obj_ctor_sentinel'        "$(last_line "$("$BIN" -e '(let [nf (Object.)] [(identical? nf nf) (identical? nf (Object.)) (identical? nf 5)])' 2>&1)")" '[true false false]'

# ADR-0109: java.lang.Number — numeric-tower supertype marker (narrow membership).
# Unblocks algo.generic.arithmetic's `(defmethod + [Number Number] …)`.
assert_eq 'isa_long_number'   "$(last_line "$("$BIN" -e '(isa? Long Number)' 2>&1)")" 'true'
assert_eq 'isa_string_number' "$(last_line "$("$BIN" -e '(isa? String Number)' 2>&1)")" 'false'
assert_eq 'inst_number_int'   "$(last_line "$("$BIN" -e '(instance? Number 5)' 2>&1)")" 'true'
assert_eq 'inst_number_ratio' "$(last_line "$("$BIN" -e '(instance? Number 1/2)' 2>&1)")" 'true'
assert_eq 'inst_number_str'   "$(last_line "$("$BIN" -e '(instance? Number "x")' 2>&1)")" 'false'

# ADR-0109: clojure.lang.IFn — callable marker (member = ifn? classes).
# Unblocks core.contracts's `(defmethod funcify* clojure.lang.IFn …)`.
assert_eq 'inst_ifn_kw'    "$(last_line "$("$BIN" -e '(instance? clojure.lang.IFn :kw)' 2>&1)")" 'true'
assert_eq 'inst_ifn_vec'   "$(last_line "$("$BIN" -e '(instance? clojure.lang.IFn [1 2])' 2>&1)")" 'true'
assert_eq 'inst_ifn_int'   "$(last_line "$("$BIN" -e '(instance? clojure.lang.IFn 5)' 2>&1)")" 'false'
assert_eq 'isa_kw_ifn'     "$(last_line "$("$BIN" -e '(isa? clojure.lang.Keyword clojure.lang.IFn)' 2>&1)")" 'true'
assert_eq 'isa_vec_ifn'    "$(last_line "$("$BIN" -e '(isa? clojure.lang.PersistentVector clojure.lang.IFn)' 2>&1)")" 'true'
assert_eq 'isa_long_ifn'   "$(last_line "$("$BIN" -e '(isa? java.lang.Long clojure.lang.IFn)' 2>&1)")" 'false'

# a genuinely-unknown class name still raises (no silent default-shift)
if "$BIN" -e '(instance? TotallyFakeClass 5)' >/dev/null 2>&1; then
    fail "unknown_class_still_errors: expected non-zero exit"
fi
echo "PASS unknown_class_still_errors"
