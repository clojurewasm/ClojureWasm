#!/usr/bin/env bash
# clojure.lang abstract-collection static hash/equality helpers (ADR-0108 am1 /
# D-375). Custom-collection deftypes call APersistentMap/mapHash etc. from their
# hashCode/hasheq/equals bodies. The corpus (clojure_lang_coll_hash.txt) covers
# the NATIVE-map fast path; this e2e locks the CRUX — mapHash over a DEFTYPE
# instance via the protocol-seq vtable walk — equals an =-equal native map's hash.

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

# --- mapHash on a deftype instance (seq-walk) == equal native map's hash.
# `cljw -` (stdin) does not echo the last value, so `prn` it explicitly. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype MyMap [m]
  clojure.lang.Seqable (seq [_] (seq m))
  Object (hashCode [this] (clojure.lang.APersistentMap/mapHash this)))
(prn (= (.hashCode (MyMap. {:a 1 :b 2})) (hash {:a 1 :b 2})))
EOF
)
assert_eq 'deftype_maphash_matches_native' "$got" 'true'

# --- mapEquals / setEquals (native, clj-faithful). `cljw -e` prints the value. ---
got=$("$BIN" -e '(clojure.lang.APersistentMap/mapEquals {:a 1 :b 2} {:b 2 :a 1})' 2>/dev/null)
assert_eq 'mapEquals_reordered' "$got" 'true'

got=$("$BIN" -e '(clojure.lang.APersistentSet/setEquals #{1 2 3} #{3 2 1})' 2>/dev/null)
assert_eq 'setEquals_reordered' "$got" 'true'

# --- Murmur3 statics agree with the clojure.core coll-hash fns ---
got=$("$BIN" -e '(= (clojure.lang.Murmur3/hashOrdered [1 2 3]) (hash-ordered-coll [1 2 3]))' 2>/dev/null)
assert_eq 'murmur3_hashordered' "$got" 'true'

echo
echo "clojure.lang coll-hash statics (ADR-0108 am1) e2e: all green."
