#!/usr/bin/env bash
# Cross-type `=` consults a deftype/reify collection's `equiv` impl (D-377).
# clj's `=` is `Util.equiv(a, b)` = the LEFT operand's equiv only (NOT symmetric):
# `(= custom-coll native)` honours the custom collection's equiv, but
# `(= native custom-coll)` consults the native map's equiv (→ false). A defrecord
# keeps its type-sensitive `=` (never `=` a plain map). Surfaced by flatland.ordered
# (`(= (ordered-map …) {…})` was false before this).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# A Box deftype whose equiv compares its backing map; clj-verified left-operand
# semantics: (= box m)=true, (= m box)=false, (= box m')=false, (= record m)=false.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Box [m]
  clojure.lang.IPersistentMap (equiv [_ o] (= m o))
  clojure.lang.Seqable (seq [_] (seq m)))
(defrecord R [a])
(prn [(= (Box. {:a 1}) {:a 1})
      (= {:a 1} (Box. {:a 1}))
      (= (Box. {:a 1}) {:a 2})
      (= (->R 1) {:a 1})
      (= (->R 1) (->R 1))])
EOF
)
assert_eq 'deftype_equiv_left_operand' "$got" '[true false false false true]'

# A MapEquivalence deftype (the data.priority-map shape) is `=` SYMMETRICALLY
# with a native map — clj's APersistentMap.equiv compares to the RIGHT operand by
# content iff it declares clojure.lang.MapEquivalence (NOT a plain IPersistentMap
# "box"). `(map? x)` is `(instance? clojure.lang.IPersistentMap x)`, so a custom
# map type answers true even without MapEquivalence. clj-verified: a MM (declares
# MapEquivalence + implements size/get/containsKey) is `=` both directions; a
# Box (IPersistentMap only) is map? but NOT `=` from a native-map LHS.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype MM [m]
  Object (equiv [_ o] (= m o))
  clojure.lang.Seqable (seq [_] (seq m))
  clojure.lang.Counted (count [_] (count m))
  clojure.lang.ILookup (valAt [_ k] (get m k)) (valAt [_ k d] (get m k d))
  clojure.lang.IPersistentMap
  clojure.lang.MapEquivalence
  java.util.Map (size [_] (count m)) (get [_ k] (get m k)) (containsKey [_ k] (contains? m k)))
(deftype Box [m]
  Object (equiv [_ o] (= m o))
  clojure.lang.Seqable (seq [_] (seq m))
  clojure.lang.IPersistentMap)
(prn [(= {:a 1 :b 2} (MM. {:a 1 :b 2}))
      (= (MM. {:a 1 :b 2}) {:a 1 :b 2})
      (= {:a 9} (MM. {:a 1}))
      (map? (MM. {:a 1}))
      (map? (Box. {:a 1}))
      (= {:a 1} (Box. {:a 1}))])
EOF
)
assert_eq 'deftype_mapequivalence_symmetric' "$got" '[true true false true true false]'

echo
echo "Cross-type deftype equiv (D-377 = facet) e2e: all green."
