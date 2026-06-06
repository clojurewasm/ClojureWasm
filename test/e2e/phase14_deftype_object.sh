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

# --- Case 3: reify Object/equals → explicit error (slice 2 pending) ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(reify Object (equals [this o] true))
EOF
)
if [[ "$diag" != *"not yet wired"* ]]; then
    fail "case3: expected Object-method-not-wired diagnostic, got '$diag'"
fi
echo "PASS reify_object_equals_explicit_error"

# --- Case 4: deftype Object/equals → explicit error ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(deftype Bar [a] Object (equals [this o] true))
(Bar. 1)
EOF
)
if [[ "$diag" != *"not yet wired"* ]]; then
    fail "case4: expected Object-method-not-wired diagnostic, got '$diag'"
fi
echo "PASS deftype_object_equals_explicit_error"

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

echo "OK — phase14_deftype_object (15 cases) green"
