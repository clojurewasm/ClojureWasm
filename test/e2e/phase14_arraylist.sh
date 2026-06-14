#!/usr/bin/env bash
# test/e2e/phase14_arraylist.sh — java.util.ArrayList (D-425). A mutable growable
# indexed list as a .host_instance over a gc.infra std.ArrayList(Value); elements
# are GC-traced (host_trace). add/get/set/size/isEmpty/contains + the
# seq/count/into bridge (Seqable -seq + IPersistentCollection -count).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# add/get/set/size/isEmpty/contains + the seq/count/into bridge.
got=$("$BIN" - <<'EOF' 2>/dev/null
(def a (java.util.ArrayList.))
(prn (.isEmpty a))            ; true
(.add a 10) (.add a 20) (.add a 30)
(prn (.size a))               ; 3
(prn (.get a 0))              ; 10
(prn (.set a 1 :x))           ; 20 (old)
(prn (.get a 1))              ; :x
(prn (.contains a 30))        ; true
(prn (.contains a 99))        ; false
(prn (seq a))                 ; (10 :x 30)
(prn (count a))               ; 3
(prn (into [] a))             ; [10 :x 30]
(prn (vec a))                 ; [10 :x 30]
EOF
) || fail "arraylist: non-zero exit ($got)"
assert_eq 'empty_true'   "$(sed -n '1p' <<< "$got")" 'true'
assert_eq 'size3'        "$(sed -n '2p' <<< "$got")" '3'
assert_eq 'get0'         "$(sed -n '3p' <<< "$got")" '10'
assert_eq 'set_old'      "$(sed -n '4p' <<< "$got")" '20'
assert_eq 'get1'         "$(sed -n '5p' <<< "$got")" ':x'
assert_eq 'contains_yes' "$(sed -n '6p' <<< "$got")" 'true'
assert_eq 'contains_no'  "$(sed -n '7p' <<< "$got")" 'false'
assert_eq 'seq'          "$(sed -n '8p' <<< "$got")" '(10 :x 30)'
assert_eq 'count'        "$(sed -n '9p' <<< "$got")" '3'
assert_eq 'into'         "$(sed -n '10p' <<< "$got")" '[10 :x 30]'
assert_eq 'vec'          "$(sed -n '11p' <<< "$got")" '[10 :x 30]'

# empty seq → nil (clj parity).
assert_eq 'empty_seq_nil' "$("$BIN" -e '(seq (java.util.ArrayList.))' 2>/dev/null | tail -1)" 'nil'

# elements survive GC (host_trace marks them).
got=$(CLJW_GC_TORTURE=1 "$BIN" - <<'EOF' 2>/dev/null
(def a (java.util.ArrayList.))
(dotimes [i 500] (.add a (str "e" i)))
(dotimes [_ 30] (doall (map inc (range 100))))
(prn [(.size a) (.get a 0) (.get a 499)])
EOF
) || fail "arraylist_gc: non-zero exit ($got)"
assert_eq 'gc_survives' "$(tail -1 <<< "$got")" '[500 "e0" "e499"]'

# ctor-from-vector (D-425 follow-up): (ArrayList. vec) seeds the list.
assert_eq 'ctor_vec'      "$("$BIN" -e '(vec (java.util.ArrayList. [1 2 3]))' 2>/dev/null | tail -1)" '[1 2 3]'
assert_eq 'ctor_vec_size' "$("$BIN" -e '(.size (java.util.ArrayList. [:a :b :c]))' 2>/dev/null | tail -1)" '3'
assert_eq 'ctor_capacity' "$("$BIN" -e '(.size (java.util.ArrayList. 16))' 2>/dev/null | tail -1)" '0'

echo "OK — phase14_arraylist (16 cases) green"
