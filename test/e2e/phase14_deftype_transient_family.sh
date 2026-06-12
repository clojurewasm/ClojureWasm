#!/usr/bin/env bash
# test/e2e/phase14_deftype_transient_family.sh
#
# D-286 — the editable / transient collection host-interface family (F-013
# definition-derived, ADR-0102). Driven by flatland.ordered, whose OrderedSet
# declares clojure.lang.IEditableCollection (the prior LOAD blocker) + IPersistentSet
# with clj-named methods, and whose Transient* types declare the ITransient* family.
# Validates:
#   - A deftype declaring IEditableCollection / ITransientSet / ITransientCollection
#     LOADS (the family names resolve as deftype host-supertype markers; bare AND
#     clojure.lang.-qualified spellings).
#   - D-286b: a deftype declaring IPersistentSet with CLJ-named methods (cons/seq/
#     count/disjoin) has conj/seq/count DISPATCH to them — the clj names are
#     translated to cljw's -cons/-seq/-count at registration (the bare-protocol-Var
#     section is routed through protocol_remap), not silently mis-registered.
#   - The self-targeting recursion guard holds (no stack-overflow segfault from the
#     D-283 dual-registration re-translating its own emitted -name).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

# --- Case 1: D-286b — conj/seq/count dispatch to clj-named IPersistentSet methods ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Box [items]
  clojure.lang.IPersistentSet
  (cons [this k] (Box. (conj items k)))
  (seq [this] (seq items))
  (disjoin [this k] (Box. (vec (remove #(= % k) items))))
  (count [this] (count items)))
(let [b (-> (Box. []) (conj :a) (conj :b))]
  (prn [(seq b) (count b)]))
EOF
) || fail "case1: non-zero exit ($got)"
[ "$got" = "[(:a :b) 2]" ] || fail "case1: expected [(:a :b) 2], got '$got'"

# --- Case 2: IEditableCollection (bare, via :import) loads + asTransient registers ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(import '(clojure.lang IEditableCollection))
(deftype EBox [x] IEditableCollection (asTransient [this] this))
(prn (instance? EBox (EBox. 1)))
EOF
) || fail "case2: non-zero exit ($got)"
[ "$got" = "true" ] || fail "case2: expected true, got '$got'"

# --- Case 3: ITransientSet (the grouped transient interface) loads ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype TBox [x]
  clojure.lang.ITransientSet
  (count [this] 0)
  (get [this k] nil)
  (disjoin [this k] this)
  (conj [this k] this)
  (contains [this k] false)
  (persistent [this] this))
(prn (instance? TBox (TBox. 1)))
EOF
) || fail "case3: non-zero exit ($got)"
[ "$got" = "true" ] || fail "case3: expected true, got '$got'"

# --- Case 4: ITransientMap (the map-side transient interface) loads ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype TMap [x]
  clojure.lang.ITransientMap
  (count [this] 0)
  (valAt [this k] nil)
  (assoc [this k v] this)
  (conj [this e] this)
  (without [this k] this)
  (persistent [this] this))
(prn (instance? TMap (TMap. 1)))
EOF
) || fail "case4: non-zero exit ($got)"
[ "$got" = "true" ] || fail "case4: expected true, got '$got'"

echo "PASS phase14_deftype_transient_family (4 cases)"
