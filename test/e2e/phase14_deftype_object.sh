#!/usr/bin/env bash
# test/e2e/phase14_deftype_object.sh
#
# D-275 slice 1 — deftype/reify host-supertype `Object` recognition +
# `Object/toString` wired to the str/print path. Validates:
#   - `(str (reify Object (toString [this] ...)))` returns the impl result
#     (the macro quote-wraps the `Object` marker so the analyzer never
#     Var-resolves it; the str path consults the Object/toString dispatch).
#   - The same for the deftype path (which lowers through extend-type),
#     including a declared field reaching the method body as an implicit local.
#   - `equals`/`hashCode` raise an explicit error (transient — slice 2 wires
#     them) rather than a silently-dropped impl.
#   - The cljw-protocol path (defprotocol + deftype/reify) is unregressed.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

# --- Case 1: reify Object/toString → str ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(str (reify Object (toString [this] "hello-obj")))
EOF
) || fail "case1: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != '"hello-obj"' ]]; then
    fail "case1: got '$last', want '\"hello-obj\"'"
fi
echo "PASS reify_object_tostring -> hello-obj"

# --- Case 2: deftype Object/toString → str, field reaches body ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Foo [a] Object (toString [this] (str "F" a)))
(str (Foo. 5))
EOF
) || fail "case2: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != '"F5"' ]]; then
    fail "case2: got '$last', want '\"F5\"'"
fi
echo "PASS deftype_object_tostring -> F5"

# --- Case 3: an UNWIRED Object method (clone) → explicit error, not silent drop ---
# (equals/hashCode are now wired by D-280d1 — see cases 16-18; clone is still
# unwired, so it must raise rather than register a no-op method.)
diag=$("$BIN" - <<'EOF' 2>&1 || true
(reify Object (clone [this] this))
EOF
)
if [[ "$diag" != *"not yet wired"* ]]; then
    fail "case3: expected Object-method-not-wired diagnostic for clone, got '$diag'"
fi
echo "PASS reify_object_unwired_method_explicit_error"

# --- Case 4: deftype unwired Object method (clone) → explicit error ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(deftype Bar [a] Object (clone [this] this))
(Bar. 1)
EOF
)
if [[ "$diag" != *"not yet wired"* ]]; then
    fail "case4: expected Object-method-not-wired diagnostic for clone, got '$diag'"
fi
echo "PASS deftype_object_unwired_method_explicit_error"

# --- Case 5: cljw-protocol path unregressed (deftype) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [x]))
(deftype T [a] P (m [this] (* a 2)))
(m (T. 21))
EOF
) || fail "case5: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "42" ]]; then
    fail "case5: got '$last', want '42'"
fi
echo "PASS protocol_deftype_unregressed -> 42"

# --- Case 6: cljw-protocol path unregressed (reify) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (m [x]))
(m (reify P (m [this] 99)))
EOF
) || fail "case6: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "99" ]]; then
    fail "case6: got '$last', want '99'"
fi
echo "PASS protocol_reify_unregressed -> 99"

# --- Case 7 (D-279): deftype method arity overload — the priority-map valAt shape ---
# `(valAt [this k]) (valAt [this k nf])` → one multi-arity fn* under (ILookup,-lookup);
# the 2-arity is reachable via (get inst k), the 3-arity via direct method call.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype T [] ILookup (-lookup [this k] :two) (-lookup [this k nf] :three))
[(get (T.) :a) (.-lookup (T.) :a :nf)]
EOF
) || fail "case7: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[:two :three]" ]]; then
    fail "case7: got '$last', want '[:two :three]'"
fi
echo "PASS deftype_method_arity_overload -> [:two :three]"

# --- Case 8 (D-279): reify method arity overload ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def r (reify ILookup (-lookup [this k] :two) (-lookup [this k nf] :three)))
[(get r :a) (.-lookup r :a :nf)]
EOF
) || fail "case8: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[:two :three]" ]]; then
    fail "case8: got '$last', want '[:two :three]'"
fi
echo "PASS reify_method_arity_overload -> [:two :three]"

# --- Case 9 (D-280a): zero-method qualified clojure.lang.*/java.io.* markers ---
# A deftype may name zero-method host markers (priority-map uses MapEquivalence +
# Serializable); they parse + record implements, alongside an Object/toString impl.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype T [a] Object (toString [this] (str "T" a)) clojure.lang.MapEquivalence java.io.Serializable)
(str (T. 9))
EOF
) || fail "case9: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != '"T9"' ]]; then
    fail "case9: got '$last', want '\"T9\"'"
fi
echo "PASS deftype_zero_method_markers -> T9"

# --- Case 10 (D-280a): a stray method on a zero-method marker errors explicitly ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(deftype T [] clojure.lang.MapEquivalence (bogus [this] 1))
(T.)
EOF
)
if [[ "$diag" != *"not yet wired"* ]]; then
    fail "case10: expected marker-method-not-wired diagnostic, got '$diag'"
fi
echo "PASS marker_stray_method_explicit_error"

# --- Case 11 (D-280b): clojure.lang.ILookup valAt → cljw get routes correctly ---
# The macro rewrites `clojure.lang.ILookup (valAt [this k] …)` to bare
# `ILookup (-lookup [this k] …)`, so (get inst k) dispatches to it.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype T [m] clojure.lang.ILookup (valAt [this k] (get m k)))
(get (T. {:a 1}) :a)
EOF
) || fail "case11: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "1" ]]; then
    fail "case11: got '$last', want '1'"
fi
echo "PASS protocol_remap_ilookup_get -> 1"

# --- Case 12 (D-280b): arity-overloaded valAt (priority-map shape) via remap ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype T [m]
  clojure.lang.ILookup
  (valAt [this k] (get m k))
  (valAt [this k nf] (get m k nf)))
[(get (T. {:a 1}) :a) (get (T. {:a 1}) :z)]
EOF
) || fail "case12: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[1 nil]" ]]; then
    fail "case12: got '$last', want '[1 nil]'"
fi
echo "PASS protocol_remap_ilookup_arity -> [1 nil]"

# --- Case 13 (D-280c): clojure.lang.IPersistentMap multi-target split ---
# clj groups count/assoc/containsKey/seq/without/empty/cons under IPersistentMap;
# the macro regroups by target cljw protocol (IPersistentCollection/Associative/
# Seqable/IPersistentMap) into a (do …) of bare extend-type sections, and the core
# fns (count/contains?/get/seq/assoc/dissoc) all route to the deftype's impls.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype M [m]
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (assoc [this k v] (M. (assoc m k v)))
  (containsKey [this k] (contains? m k))
  (seq [this] (seq m))
  (without [this k] (M. (dissoc m k)))
  (empty [this] (M. {}))
  (cons [this e] (M. (conj m e)))
  clojure.lang.ILookup
  (valAt [this k] (get m k)))
(def x (M. {:a 1}))
[(count x) (contains? x :a) (get x :a) (get (assoc x :b 2) :b) (count (dissoc (assoc x :b 2) :a))]
EOF
) || fail "case13: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[1 true 1 2 1]" ]]; then
    fail "case13: got '$last', want '[1 true 1 2 1]'"
fi
echo "PASS protocol_remap_ipersistentmap_multitarget -> [1 true 1 2 1]"

# --- Case 14 (D-280d3): clojure.lang.Reversible rseq routes via the modeled protocol ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype R [v] clojure.lang.Reversible (rseq [this] (reverse v)))
(rseq (R. [1 2 3]))
EOF
) || fail "case14: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "(3 2 1)" ]]; then
    fail "case14: got '$last', want '(3 2 1)'"
fi
echo "PASS protocol_remap_reversible_rseq -> (3 2 1)"

# --- Case 15 (D-280d2): clojure.lang.IPersistentStack peek/pop via core.clj consult ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype S [v]
  clojure.lang.IPersistentStack
  (peek [this] (last v))
  (pop [this] (S. (butlast v))))
(let [s (S. [1 2 3])] [(peek s) (vec (.-v (pop s)))])
EOF
) || fail "case15: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[3 [1 2]]" ]]; then
    fail "case15: got '$last', want '[3 [1 2]]'"
fi
echo "PASS protocol_remap_ipersistentstack_peek_pop -> [3 [1 2]]"

# --- Case 16 (D-280d1): Object equals overrides identity (same-type) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype P [v] Object (equals [this o] (= v (.-v o))))
[(= (P. 1) (P. 1)) (= (P. 1) (P. 2))]
EOF
) || fail "case16: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[true false]" ]]; then
    fail "case16: got '$last', want '[true false]'"
fi
echo "PASS object_equals_same_type -> [true false]"

# --- Case 17 (D-280d1): Object hashCode overrides default value-hash ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype P [v] Object (hashCode [this] (* v 100)))
(hash (P. 7))
EOF
) || fail "case17: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "700" ]]; then
    fail "case17: got '$last', want '700'"
fi
echo "PASS object_hashcode -> 700"

# --- Case 18 (D-280d1): a deftype WITHOUT Object equals keeps identity = ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Q [v])
[(= (Q. 1) (Q. 1)) (let [x (Q. 1)] (= x x))]
EOF
) || fail "case18: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[false true]" ]]; then
    fail "case18: got '$last', want '[false true]'"
fi
echo "PASS deftype_no_equals_keeps_identity -> [false true]"

# --- Case 19 (D-280d1b): Object hashCode/equals declared in the IPersistentMap
# section (priority-map shape) route to the Object method-family + are consulted ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype M [m]
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (equals [this o] (= m (.-m o)))
  (hashCode [this] (* (count m) 1000)))
[(= (M. {:x 1}) (M. {:x 1})) (= (M. {:x 1}) (M. {:y 2})) (hash (M. {:x 1})) (count (M. {:x 1}))]
EOF
) || fail "case19: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[true false 1000 1]" ]]; then
    fail "case19: got '$last', want '[true false 1000 1]'"
fi
echo "PASS object_methods_in_ipersistentmap_section -> [true false 1000 1]"

# --- Case 20 (D-280d5): clojure.lang.IHashEq hasheq drives (hash inst), preferred over hashCode ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype H [v]
  Object (hashCode [this] 1)
  clojure.lang.IHashEq (hasheq [this] (* v 7)))
[(hash (H. 9)) (hash (H. 0))]
EOF
) || fail "case20: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[63 0]" ]]; then
    fail "case20: got '$last', want '[63 0]'"
fi
echo "PASS ihasheq_hasheq_preferred -> [63 0]"

# --- Case 21 (D-280d8): equiv (clj collection =) + entryAt register and work ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype M [m]
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (equiv [this o] (= m (.-m o)))
  (entryAt [this k] [k (get m k)]))
[(= (M. {:a 1}) (M. {:a 1})) (= (M. {:a 1}) (M. {:a 2})) (count (M. {:a 1}))]
EOF
) || fail "case21: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[true false 1]" ]]; then
    fail "case21: got '$last', want '[true false 1]'"
fi
echo "PASS equiv_same_type_and_entryAt -> [true false 1]"

# --- Case 22 (D-280d4): clojure.lang.Sorted registers + dispatches all 4 methods ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Srt [m]
  clojure.lang.Sorted
  (comparator [this] :cmp)
  (entryKey [this e] (first e))
  (seq [this ascending] (if ascending :asc :desc))
  (seqFrom [this k ascending] [k ascending]))
(let [s (Srt. {})] [(-sorted-comparator s) (-entry-key s [:a 1]) (-sorted-seq s true) (-sorted-seq-from s :k false)])
EOF
) || fail "case22: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[:cmp :a :asc [:k false]]" ]]; then
    fail "case22: got '$last', want '[:cmp :a :asc [:k false]]'"
fi
echo "PASS protocol_remap_sorted -> ok"

# --- Case 23 (D-280d6/d7): clojure.lang.IFn (multi-arity invoke) + IObj register ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype F [v]
  clojure.lang.IFn
  (invoke [this k] (get v k))
  (invoke [this k nf] (get v k nf))
  clojure.lang.IObj
  (meta [this] :my-meta)
  (withMeta [this m] (F. v)))
(let [f (F. {:a 1})] [(-invoke f :a) (-invoke f :z :def) (-meta f)])
EOF
) || fail "case23: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[1 :def :my-meta]" ]]; then
    fail "case23: got '$last', want '[1 :def :my-meta]'"
fi
echo "PASS protocol_remap_ifn_iobj -> [1 :def :my-meta]"

# --- Case 24 (D-280d6 functional): an IFn deftype is callable as (inst args) ---
# The call switch (shared treeWalkCall = both backends) consults IFn/-invoke.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype F [m]
  clojure.lang.IFn
  (invoke [this k] (get m k))
  (invoke [this k nf] (get m k nf)))
(let [f (F. {:a 1})] [(f :a) (f :z :default) (map f [:a :z])])
EOF
) || fail "case24: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[1 :default (1 nil)]" ]]; then
    fail "case24: got '$last', want '[1 :default (1 nil)]'"
fi
echo "PASS ifn_deftype_callable -> [1 :default (1 nil)]"

# --- Case 25 (D-280d7 functional): meta/with-meta consult IObj on a deftype ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype O [m _meta]
  clojure.lang.IObj
  (meta [this] _meta)
  (withMeta [this nm] (O. m nm)))
(let [o (O. {:a 1} {:tag :orig})] [(meta o) (meta (with-meta o {:tag :new}))])
EOF
) || fail "case25: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[{:tag :orig} {:tag :new}]" ]]; then
    fail "case25: got '$last', want '[{:tag :orig} {:tag :new}]'"
fi
echo "PASS iobj_meta_with_meta -> orig/new"

# --- Case 26 (D-282): clojure.core.protocols ns + a deftype implementing
# clojure.core.protocols/IKVReduce loads and dispatches kv-reduce ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.core.protocols)
(deftype KV [m]
  clojure.core.protocols/IKVReduce
  (kv-reduce [this f init] (reduce-kv f init m)))
(clojure.core.protocols/kv-reduce (KV. {:a 1 :b 2}) (fn [acc k v] (+ acc v)) 0)
EOF
) || fail "case26: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "3" ]]; then
    fail "case26: got '$last', want '3'"
fi
echo "PASS core_protocols_ikvreduce -> 3"

# --- Case 27 (D-281): host_inert java.util.Map + java.lang.Iterable load alongside
# clojure.lang.* — the deftype parses; clojure.lang.* methods route, java methods inert ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype M [m]
  clojure.lang.ILookup
  (valAt [this k] (get m k))
  clojure.lang.IPersistentMap
  (count [this] (count m))
  Map
  (size [this] (count m))
  (put [this k v] (throw (ex-info "immutable" {})))
  Iterable
  (iterator [this] nil))
(let [x (M. {:a 1 :b 2})] [(count x) (get x :a) (.size x)])
EOF
) || fail "case27: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[2 1 2]" ]]; then
    fail "case27: got '$last', want '[2 1 2]'"
fi
echo "PASS host_inert_java_util_map_iterable -> [2 1 2]"

# --- Case 28 (D-283): clj-name `.method` dot-calls resolve on a protocol_remap
# deftype (registered under both the cljw name [core fns] and the clj name [dot]) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype M [m]
  clojure.lang.ILookup
  (valAt [this k] (get m k))
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (assoc [this k v] (M. (assoc m k v))))
(let [x (M. {:a 1})] [(get x :a) (.valAt x :a) (count (.assoc x :b 2))])
EOF
) || fail "case28: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[1 1 2]" ]]; then
    fail "case28: got '$last', want '[1 1 2]'"
fi
echo "PASS protocol_remap_clj_name_dotcall -> [1 1 2]"

# --- Case 29 (D-284): (MapEntry. k v) constructs cljw's 2-vector entry ---
got=$("$BIN" - <<'EOF' 2>/dev/null
[(MapEntry. :a 1) (key (MapEntry. :a 1)) (val (new clojure.lang.MapEntry :b 2))]
EOF
) || fail "case29: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[[:a 1] :a 2]" ]]; then
    fail "case29: got '$last', want '[[:a 1] :a 2]'"
fi
echo "PASS map_entry_ctor -> [[:a 1] :a 2]"

# --- Case 30 (D-285): keys/vals derive from seq for a map deftype (no -keys impl) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype M [m]
  clojure.lang.IPersistentMap
  (count [this] (count m))
  (seq [this] (seq m)))
(let [x (M. {:a 1 :b 2})] [(keys x) (vals x)])
EOF
) || fail "case30: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[(:a :b) (1 2)]" ]]; then
    fail "case30: got '$last', want '[(:a :b) (1 2)]'"
fi
echo "PASS keys_vals_seq_derive -> [(:a :b) (1 2)]"

# --- Case 31 (D-286a): bare IHashEq + the java.util collection host_inert family
# (Set/List/Collection), as used via `(:import [clojure.lang …] [java.util …])` ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype S [v]
  IHashEq (hasheq [this] (* v 5))
  Set (size [this] v)
  java.util.List (get [this i] i))
[(hash (S. 4)) (.size (S. 9))]
EOF
) || fail "case31: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[20 9]" ]]; then
    fail "case31: got '$last', want '[20 9]'"
fi
echo "PASS bare_ihasheq_java_util_family -> [20 9]"

# --- Case 32 (D-291): java.io.Closeable host_inert — a deftype declaring it +
# implementing `(close …)` with a body LOADS (the body is accepted-and-recorded,
# never dispatched), and the type's real protocol method still works. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol Reader (rc [r]))
(deftype SR [s]
  Reader (rc [this] s)
  Closeable (close [this] :closed))
[(rc (->SR :x)) (.close (->SR :y))]
EOF
) || fail "case32: non-zero exit ($got)"
last=$(awk 'END { print }' <<< "$got")
if [[ "$last" != "[:x :closed]" ]]; then
    fail "case32: got '$last', want '[:x :closed]'"
fi
echo "PASS closeable_host_inert_with_body -> [:x :closed]"

echo "OK — phase14_deftype_object (32 cases) green"
