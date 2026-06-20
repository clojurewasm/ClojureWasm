#!/usr/bin/env bash
# test/e2e/phase14_treeset.sh — java.util.TreeSet (D-431 interop completeness).
# A mutable SORTED set as a .host_instance over a cljw persistent sorted-set
# (RB-tree, GC-traced via host_trace). add/remove/contains/size/isEmpty/clear/
# addAll/first/last + the seq/count/into bridge. Iteration is SORTED = clj parity
# (unlike HashSet, the seq order is tested DIRECTLY, no sort wrap).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# add (changed-bool, dedup) / sorted seq / first / last / contains / remove.
got=$("$BIN" - <<'EOF' 2>/dev/null
(def t (java.util.TreeSet.))
(prn (.isEmpty t))             ; true
(prn [(.add t 3) (.add t 1) (.add t 2) (.add t 1)])  ; [true true true false]
(prn (seq t))                  ; (1 2 3)  SORTED
(prn [(.first t) (.last t) (.size t)])               ; [1 3 3]
(prn [(.contains t 2) (.contains t 9)])              ; [true false]
(prn (.remove t 1))            ; true
(prn (seq t))                  ; (2 3)
EOF
)
exp=$'true\n[true true true false]\n(1 2 3)\n[1 3 3]\n[true false]\ntrue\n(2 3)'
assert_eq 'treeset_core' "$got" "$exp"

# seed from a vector (sort+dedup) + into/count bridge + clear + addAll(vector).
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (seq (java.util.TreeSet. [5 3 1 4 2 2])))       ; (1 2 3 4 5)
(prn (into [] (java.util.TreeSet. [3 1 2])))         ; [1 2 3]
(prn (count (java.util.TreeSet. ["c" "a" "b" "a"]))) ; 3
(def u (java.util.TreeSet. [10 20]))
(prn (.addAll u [15 5 25]))    ; true
(prn (seq u))                  ; (5 10 15 20 25)
(.clear u)
(prn (.isEmpty u))             ; true
EOF
)
exp=$'(1 2 3 4 5)\n[1 2 3]\n3\ntrue\n(5 10 15 20 25)\ntrue'
assert_eq 'treeset_seed_bridge' "$got" "$exp"

# seed by SHARING another sorted-set / TreeSet (immutable — source unaffected).
got=$("$BIN" - <<'EOF' 2>/dev/null
(def src (java.util.TreeSet. [1 2 3]))
(def cp (java.util.TreeSet. src))
(.add cp 4)
(prn [(.size src) (.size cp)])                       ; [3 4]
(prn (seq (java.util.TreeSet. (sorted-set 9 7 8))))  ; (7 8 9)
EOF
)
exp=$'[3 4]\n(7 8 9)'
assert_eq 'treeset_share' "$got" "$exp"

# .first / .last on an empty set raise (no silent nil); addAll non-vector raises.
diag=$("$BIN" -e '(.first (java.util.TreeSet.))' 2>&1 || true)
case "$diag" in *"TreeSet/first"*|*"out of"*|*"range"*) echo "PASS treeset_first_empty_raises" ;; *) fail "treeset_first_empty: got '$diag'" ;; esac
diag=$("$BIN" -e '(.addAll (java.util.TreeSet.) (list 1 2))' 2>&1 || true)
case "$diag" in *"vector"*) echo "PASS treeset_addall_nonvector_raises" ;; *) fail "treeset_addall_nonvector: got '$diag'" ;; esac

echo
echo "java.util.TreeSet e2e: all green."
