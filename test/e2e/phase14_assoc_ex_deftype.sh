#!/usr/bin/env bash
# `assocEx` on a deftype's clojure.lang.IPersistentMap section.
#
# clj's IPersistentMap declares assocEx (assoc that THROWS when the key is
# already present), so a type implementing the interface faithfully declares it.
# cljw's IPERSISTENT_MAP remap table had no row for the name, so the whole
# deftype raised "deftype/reify clojure.lang.* method not yet wired" at LOAD —
# one unwired name taking down every type that declares it.
#
# Found against replikativ/boring: `boring.data`'s UnknownRecord declares
# assocEx between `assoc` and `without`, and the namespace would not load on
# cljw at all. That blocks the whole CBOR stack (boring is a dep of datahike,
# kabel and konserve-sync).
#
# `(.assocEx native-map k v)` is deliberately still unwired — see the comment on
# the remap row in runtime/host_interface.zig. There is no clojure.core fn with
# assocEx's semantics and mapping it to `assoc` would answer a different
# question silently.

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

# The regression itself: the type LOADS, and its siblings in the same
# IPersistentMap section keep dispatching.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Rec [m]
  clojure.lang.ILookup
  (valAt [_ k] (get m k))
  clojure.lang.IPersistentMap
  (assoc [_ k v] (Rec. (assoc m k v)))
  (assocEx [_ k v] (if (contains? m k)
                     (throw (Exception. "Key already present"))
                     (Rec. (assoc m k v))))
  (without [_ k] (Rec. (dissoc m k)))
  clojure.lang.Seqable (seq [_] (seq m)))
(let [r (assoc (Rec. {}) :a 1)]
  (prn [(.valAt r :a) (seq (.without r :a)) (seq r)]))
EOF
)
assert_eq 'assoc_ex_declared_type_loads' "$got" '[1 nil ([:a 1])]'

# The declaring type's own assocEx body is what runs: absent key assocs.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Rec2 [m]
  clojure.lang.ILookup (valAt [_ k] (get m k))
  clojure.lang.IPersistentMap
  (assoc [_ k v] (Rec2. (assoc m k v)))
  (assocEx [_ k v] (if (contains? m k)
                     (throw (Exception. "Key already present"))
                     (Rec2. (assoc m k v)))))
(prn (.valAt (.assocEx (Rec2. {}) :x 7) :x))
EOF
)
assert_eq 'assoc_ex_dispatches_to_body' "$got" '7'

# ...and a present key throws, which is the whole reason the method is distinct
# from assoc. A silent assoc here would be the wrong answer, not a slow one.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Rec3 [m]
  clojure.lang.IPersistentMap
  (assoc [_ k v] (Rec3. (assoc m k v)))
  (assocEx [_ k v] (if (contains? m k)
                     (throw (Exception. "Key already present"))
                     (Rec3. (assoc m k v)))))
(prn (try (.assocEx (Rec3. {:x 1}) :x 2) :no-throw
          (catch Exception _ :threw)))
EOF
)
assert_eq 'assoc_ex_throws_on_present' "$got" ':threw'

# The cljw-native spelling of the same protocol method round-trips too — the
# identity row (`-assoc-ex` -> `-assoc-ex`) that every IPersistentMap method
# needs so a cljw-form extend-type section passes through unrewritten.
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Rec4 [m])
(extend-type Rec4
  clojure.core/IPersistentMap
  (-assoc-ex [_ k v] [:native k v]))
(prn (clojure.core/-assoc-ex (Rec4. {}) :k :v))
EOF
)
assert_eq 'assoc_ex_native_extend_type' "$got" '[:native :k :v]'

echo
echo "assocEx on a deftype IPersistentMap section e2e: all green."
