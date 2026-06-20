#!/usr/bin/env bash
# test/e2e/phase14_hashset.sh — java.util.HashSet (D-431 interop completeness).
# A mutable set as a .host_instance over a cljw PERSISTENT SET Value (HAMT dedup,
# GC-traced via host_trace). add/remove/contains/size/isEmpty/clear/addAll + the
# seq/count/into bridge (Seqable -seq + IPersistentCollection -count). Iteration
# order is cljw HAMT order, not clj hash order (AD-001 class) — tests sort/set.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# add (changed-bool, dedup) / contains / size / isEmpty / remove / seq / count.
got=$("$BIN" - <<'EOF' 2>/dev/null
(def s (java.util.HashSet.))
(prn (.isEmpty s))             ; true
(prn [(.add s 1) (.add s 1) (.add s 2) (.add s 3)])  ; [true false true true]
(prn (.size s))                ; 3
(prn [(.contains s 2) (.contains s 9)])              ; [true false]
(prn (.remove s 2))            ; true
(prn (.remove s 2))            ; false (already gone)
(prn (sort (seq s)))           ; (1 3)
(prn (count s))                ; 3? no -> 2
EOF
)
exp=$'true\n[true false true true]\n3\n[true false]\ntrue\nfalse\n(1 3)\n2'
assert_eq 'hashset_core' "$got" "$exp"

# seed from a vector (dedup) + into/set bridge + clear + addAll(vector).
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (.size (java.util.HashSet. [1 1 2 3 3 3])))     ; 3
(prn (sort (set (java.util.HashSet. [:a :b :a]))))   ; (:a :b)
(prn (sort (into [] (java.util.HashSet. [3 1 2]))))  ; (1 2 3)
(def t (java.util.HashSet. [10 20]))
(prn (.addAll t [20 30 40]))   ; true (changed)
(prn (.addAll t [10 20]))      ; false (no change)
(prn (sort (seq t)))           ; (10 20 30 40)
(.clear t)
(prn (.isEmpty t))             ; true
EOF
)
exp=$'3\n(:a :b)\n(1 2 3)\ntrue\nfalse\n(10 20 30 40)\ntrue'
assert_eq 'hashset_seed_bridge' "$got" "$exp"

# seed by SHARING another set / HashSet's HAMT (immutable — source unaffected).
got=$("$BIN" - <<'EOF' 2>/dev/null
(def src (java.util.HashSet. [1 2 3]))
(def cp (java.util.HashSet. src))
(.add cp 4)
(prn [(.size src) (.size cp)])                       ; [3 4]
(prn (sort (seq (java.util.HashSet. #{:x :y}))))     ; (:x :y)
EOF
)
exp=$'[3 4]\n(:x :y)'
assert_eq 'hashset_share' "$got" "$exp"

# addAll of a non-vector seqable raises (no silent mishandle) — use (vec coll).
diag=$("$BIN" -e '(.addAll (java.util.HashSet.) (list 1 2))' 2>&1 || true)
case "$diag" in
    *"vector"*) echo "PASS hashset_addall_nonvector_raises -> diagnostic" ;;
    *) fail "hashset_addall_nonvector: expected a vector type error, got '$diag'" ;;
esac

echo
echo "java.util.HashSet e2e: all green."
