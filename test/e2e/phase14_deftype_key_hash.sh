#!/usr/bin/env bash
# A deftype/reify with a custom Object/hasheq + equiv participates in HAMT key
# bucketing & comparison — so it dedups & looks up against an `=`-equal value
# (D-377 facet 2, ADR-0129). Before this, the HAMT key-hash/key-equal sites were
# rt-free (`equal.valueHash`/`keyEqValue`) and could not dispatch a deftype's
# user hasheq/equiv, so a custom-hash deftype as a map key / set element fell to
# identity → no dedup, no lookup. clj-verified ground truth (a Box whose equiv is
# true for any Box, hasheq=7): conj-dedup is SYMMETRIC (both orders → 1), map get
# + set contains find the `=`-equal key.

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

# Box: hasheq const 7, equals true for any Box (so any two Boxes are `=` keys).
# clj oracle (runtime conj, not the dup-rejecting set literal):
#   [:ab 1 :ba 1 :get :x :contains true]
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Box [v]
  clojure.lang.IHashEq (hasheq [_] 7)
  Object (equals [_ o] (instance? Box o)) (hashCode [_] 7))
(let [a (->Box 1) b (->Box 2)]
  (prn [(count (conj (conj #{} a) b))
        (count (conj (conj #{} b) a))
        (get (assoc {} a :x) b)
        (contains? (conj #{} a) b)]))
EOF
)
assert_eq 'deftype_custom_hash_key' "$got" '[1 1 :x true]'

# The `(hash x)` primitive already dispatched hasheq (D-280d1/d5); confirm it
# still does and now AGREES with the key path (same dispatch core, ADR-0129 F-011).
got2=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Box [v] clojure.lang.IHashEq (hasheq [_] 12345))
(prn (hash (->Box 1)))
EOF
)
assert_eq 'hash_primitive_dispatches_hasheq' "$got2" '12345'

# A deftype WITHOUT a custom hasheq keeps identity semantics (two distinct
# instances are distinct keys) — the consult must not over-fire.
got3=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Plain [v])
(prn (count (conj (conj #{} (->Plain 1)) (->Plain 1))))
EOF
)
assert_eq 'plain_deftype_identity_keys' "$got3" '2'

echo
echo "deftype custom hasheq+equiv as HAMT key (D-377 facet 2) e2e: all green."
