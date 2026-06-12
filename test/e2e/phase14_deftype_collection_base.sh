#!/usr/bin/env bash
# test/e2e/phase14_deftype_collection_base.sh — D-306 (ADR-0102, F-013).
# A deftype may declare the clojure.lang collection-BASE interfaces
# (IPersistentCollection / Counted / Associative / Seqable) DIRECTLY as
# supertypes — not only grouped under IPersistentMap. These are the
# interfaces clj's IPersistentMap decomposes into; core.cache's `defcache`
# macro names them directly. Recognised via host_interfaces.yaml (qualified
# spelling), remapped to the same cljw (protocol, method) targets
# IPersistentMap uses, so count/seq/contains? dispatch through the instance.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

FIX=/tmp/phase14_collbase_$$.clj
cat > "$FIX" <<'CLJ'
(deftype Wrap [m]
  clojure.lang.Counted
  (count [_] (count m))
  clojure.lang.Seqable
  (seq [_] (seq m))
  clojure.lang.Associative
  (containsKey [_ k] (contains? m k))
  (entryAt [_ k] (find m k))
  clojure.lang.IPersistentCollection
  (cons [_ e] (conj m e))
  (empty [_] {})
  (equiv [_ o] (= m o)))
(def w (->Wrap {:a 1 :b 2}))
(println "count" (count w))
(println "seq" (seq w))
(println "contains" (contains? w :a))
(println "miss" (contains? w :z))
CLJ
out="$("$BIN" "$FIX" 2>&1)"
rm -f "$FIX"
assert_eq 'load+count' "$(printf '%s' "$out" | grep '^count' | tail -1)" 'count 2'
assert_eq 'seq'        "$(printf '%s' "$out" | grep '^seq'   | tail -1)" 'seq ([:a 1] [:b 2])'
assert_eq 'contains'   "$(printf '%s' "$out" | grep '^contains' | tail -1)" 'contains true'
assert_eq 'miss'       "$(printf '%s' "$out" | grep '^miss'  | tail -1)" 'miss false'

# A standalone Counted-only deftype also resolves the qualified base interface.
COUNTED_OUT="$("$BIN" -e '(deftype C [n] clojure.lang.Counted (count [_] n)) (count (->C 7))' 2>&1 | tail -1)"
assert_eq 'counted_only' "$COUNTED_OUT" '7'

# instance? sees the DECLARED interface even when its methods all remap to
# OTHER cljw protocols (IPersistentMap's count/assoc/… scatter to
# IPersistentCollection/Associative/…, so the declared name itself must be
# recorded; clj: (instance? clojure.lang.IPersistentMap pm) is plainly true).
INSTANCE_OUT="$("$BIN" - <<'CLJ' 2>&1 | tail -1
(deftype Pm [m]
  clojure.lang.IPersistentMap
  (count [_] (count m))
  (assoc [_ k v] (Pm. (assoc m k v))))
(prn [(instance? clojure.lang.IPersistentMap (->Pm {:a 1}))
      (instance? clojure.lang.IPersistentMap {:a 1})
      (instance? clojure.lang.IPersistentMap [1])])
CLJ
)"
assert_eq 'declared_iface_instance' "$INSTANCE_OUT" '[true true false]'

# A ZERO-method protocol_remap declaration loads and records the marker
# (was: "__extend-type!: expected protocol, got type_descriptor").
ZERO_OUT="$("$BIN" - <<'CLJ' 2>&1 | tail -1
(deftype Z [m] clojure.lang.IPersistentMap)
(prn (instance? clojure.lang.IPersistentMap (->Z {})))
CLJ
)"
assert_eq 'zero_method_remap_decl' "$ZERO_OUT" 'true'

# An IPersistentMap-declaring deftype PRINTS map-style from its seq (clj:
# core_print's defmethod on the clojure.lang.IPersistentMap interface class;
# data.priority-map prints {:b 1, :c 2, :a 3} in priority order, not
# #PersistentPriorityMap[…]). Nested + seq-order preservation included.
PRINT_OUT="$("$BIN" - <<'CLJ' 2>&1 | tail -2
(deftype Pm [m]
  clojure.lang.IPersistentMap
  (count [_] (count m))
  clojure.lang.Seqable
  (seq [_] (reverse (seq m))))
(prn (->Pm {:a 1 :b 2}))
(prn [{:x (->Pm {:a 1})}])
CLJ
)"
assert_eq 'maplike_print' "$PRINT_OUT" '{:b 2, :a 1}
[{:x {:a 1}}]'

echo "OK — phase14_deftype_collection_base (8 cases) green"
