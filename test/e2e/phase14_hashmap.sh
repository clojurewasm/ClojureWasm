#!/usr/bin/env bash
# test/e2e/phase14_hashmap.sh — java.util.HashMap (D-425). A mutable key→value
# map as a .host_instance backing a cljw MAP Value in state[0] (reusing cljw
# hashing/equality); the one map Value is GC-traced (host_trace). put/get/
# containsKey/size/isEmpty/remove + the seq/count/into bridge.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

got=$("$BIN" - <<'EOF' 2>/dev/null
(def m (java.util.HashMap.))
(prn (.isEmpty m))            ; true
(prn (.put m :a 1))           ; nil (no previous)
(.put m :b 2)
(prn (.put m :a 9))           ; 1 (previous)
(prn (.get m :a))             ; 9
(prn (.get m :z))             ; nil (absent)
(prn (.containsKey m :b))     ; true
(prn (.size m))               ; 2
(prn (.remove m :b))          ; 2 (previous)
(prn (.size m))               ; 1
(prn (into {} m))             ; {:a 9}
(prn (count m))               ; 1
(prn (seq m))                 ; ([:a 9]) — cljw MapEntry (AD-032)
EOF
) || fail "hashmap: non-zero exit ($got)"
assert_eq 'empty_true'   "$(sed -n '1p' <<< "$got")" 'true'
assert_eq 'put_nil'      "$(sed -n '2p' <<< "$got")" 'nil'
assert_eq 'put_old'      "$(sed -n '3p' <<< "$got")" '1'
assert_eq 'get'          "$(sed -n '4p' <<< "$got")" '9'
assert_eq 'get_absent'   "$(sed -n '5p' <<< "$got")" 'nil'
assert_eq 'containsKey'  "$(sed -n '6p' <<< "$got")" 'true'
assert_eq 'size2'        "$(sed -n '7p' <<< "$got")" '2'
assert_eq 'remove_old'   "$(sed -n '8p' <<< "$got")" '2'
assert_eq 'size1'        "$(sed -n '9p' <<< "$got")" '1'
assert_eq 'into'         "$(sed -n '10p' <<< "$got")" '{:a 9}'
assert_eq 'count'        "$(sed -n '11p' <<< "$got")" '1'
# AD-032: (seq hm) yields cljw MapEntry pairs, not clj's java.util.HashMap$Node
# (which embeds a non-reproducible identity hash) — into/keys/vals are identical.
assert_eq 'seq_cljw_entry' "$(sed -n '12p' <<< "$got")" '([:a 9])'

# empty seq → nil (clj parity).
assert_eq 'empty_seq_nil' "$("$BIN" -e '(seq (java.util.HashMap.))' 2>/dev/null | tail -1)" 'nil'

# entries survive GC (host_trace marks the backing map Value).
got=$(CLJW_GC_TORTURE=1 "$BIN" - <<'EOF' 2>/dev/null
(def m (java.util.HashMap.))
(dotimes [i 400] (.put m (str "k" i) (str "v" i)))
(dotimes [_ 30] (doall (map inc (range 100))))
(prn [(.size m) (.get m "k0") (.get m "k399")])
EOF
) || fail "hashmap_gc: non-zero exit ($got)"
assert_eq 'gc_survives' "$(tail -1 <<< "$got")" '[400 "v0" "v399"]'

# ctor-from-map (D-425 follow-up): (HashMap. m) seeds from a cljw map; .put on
# the HashMap does NOT mutate the source (persistent sharing).
assert_eq 'ctor_map'     "$("$BIN" -e '(into {} (java.util.HashMap. {:a 1 :b 2}))' 2>/dev/null | tail -1)" '{:a 1, :b 2}'
assert_eq 'ctor_map_get' "$("$BIN" -e '(.get (java.util.HashMap. {:x 9}) :x)' 2>/dev/null | tail -1)" '9'
got=$("$BIN" - <<'EOF' 2>/dev/null
(def src {:a 1})
(def m (java.util.HashMap. src))
(.put m :b 2)
(prn (count src))   ; 1 — source unmutated
(prn (.size m))     ; 2
EOF
) || fail "ctor_src_immut: non-zero exit ($got)"
assert_eq 'ctor_src_immut'  "$(sed -n '1p' <<< "$got")" '1'
assert_eq 'ctor_after_put'  "$(sed -n '2p' <<< "$got")" '2'

echo "OK — phase14_hashmap (18 cases) green"
