#!/usr/bin/env bash
# Multi-pair assoc on an Associative deftype/extend-type receiver (D-378). clj's
# `(assoc m k1 v1 k2 v2 …)` reduces over pairs; cljw now folds the multi-pair form
# into repeated single-pair `-assoc` for a protocol receiver (was: raised
# "multi-pair assoc on extend-type Associative receiver"). Unblocks
# flatland.ordered's `(apply assoc empty-ordered-map …)` ctor.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# A deftype implementing Associative -assoc + ILookup + Seqable; multi-pair assoc
# folds into single-pair calls (each re-dispatches -assoc on the prior result).
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Box [m]
  clojure.lang.Associative
  (assoc [_ k v] (Box. (assoc m k v)))
  clojure.lang.ILookup (valAt [_ k] (get m k))
  clojure.lang.Seqable (seq [_] (seq m)))
(let [b (assoc (Box. {}) :a 1 :b 2 :c 3)]
  (prn [(.valAt b :a) (.valAt b :b) (.valAt b :c) (seq b)]))
EOF
)
assert_eq 'multipair_assoc_fold' "$got" '[1 2 3 ([:a 1] [:b 2] [:c 3])]'

# Single-pair still works (the fold's 1-iteration case).
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Box2 [m]
  clojure.lang.Associative (assoc [_ k v] (Box2. (assoc m k v)))
  clojure.lang.ILookup (valAt [_ k] (get m k)))
(prn (.valAt (assoc (Box2. {}) :x 7) :x))
EOF
)
assert_eq 'singlepair_assoc' "$got" '7'

echo
echo "Multi-pair assoc on Associative deftype (D-378) e2e: all green."
