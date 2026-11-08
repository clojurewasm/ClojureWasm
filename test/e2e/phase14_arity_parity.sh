#!/usr/bin/env bash
# e2e: arity-divergence parity with JVM Clojure (D-446).
# The arity audit (2026-06-16) found fns whose accepted ARITY set diverged
# from clj — silent "works in cljw, throws in clj" (or vice versa) bugs.
# This pins the clj-aligned boundaries so a regression re-surfaces here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLJW="$ROOT/zig-out/bin/cljw"

pass=0
fail=0

# Exact-output check (value-producing).
check() {
  local desc="$1" expr="$2" want="$3" got
  got="$("$CLJW" -e "$expr" 2>&1)" || true
  if [[ "$got" == "$want" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $desc"; echo "  expr: $expr"; echo "  want: $want"; echo "  got:  $got"
  fi
}

# Arity-error check: the call must raise an arity error (matches clj's
# ArityException). Greps for cljw's "Wrong number of args" render.
check_arity_err() {
  local desc="$1" expr="$2" got
  got="$("$CLJW" -e "$expr" 2>&1)" || true
  if [[ "$got" == *"Wrong number of args"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL (expected arity error): $desc"; echo "  expr: $expr"; echo "  got:  $got"
  fi
}

# --- cljw-lenient bugs fixed: these now THROW at 0-arg (clj parity) ---
check_arity_err "(=) throws"          '(=)'
check_arity_err "(<) throws"          '(<)'
check_arity_err "(>) throws"          '(>)'
check_arity_err "(<=) throws"         '(<=)'
check_arity_err "(>=) throws"         '(>=)'
check_arity_err "(distinct?) throws"  '(distinct?)'
check_arity_err "(every-pred) throws" '(every-pred)'
check_arity_err "(some-fn) throws"    '(some-fn)'
# Valid arities of the same fns still work (no over-correction).
check "(= 1) is true"        '(= 1)'        'true'
check "(< 1) is true"        '(< 1)'        'true'
check "(distinct? 1) true"   '(distinct? 1)' 'true'
check "(distinct? 1 1) false" '(distinct? 1 1)' 'false'
check "(every-pred pos?) fn works" '((every-pred pos?) 3)' 'true'
check "(some-fn pos?) fn works"    '((some-fn neg?) 3)'    'false'

# --- cljw-strict bugs fixed: these now RETURN clj's value (0/1 arity) ---
check "(into) is []"             '(into)'                              '[]'
check "(into [9]) is [9]"        '(into [9])'                          '[9]'
check "(into [9] [1 2]) works"   '(into [9] [1 2])'                    '[9 1 2]'
check "(persistent! (conj!)) []" '(persistent! (conj!))'              '[]'
check "(conj! coll) returns coll" '(persistent! (conj! (transient [1])))' '[1]'
check "(conj! coll x) still works" '(persistent! (conj! (transient [1]) 2))' '[1 2]'

# --- cljw-strict (missing arity) bugs fixed: n-ary / variadic forms clj
#     accepts but cljw used to reject (D-446 residual sweep, 2026-06-18). ---
# n-ary map/mapv/mapcat: zip 4+ colls, stopping at the shortest.
check "(map + 4 colls)"   '(map + [1 2] [10 20] [100 200] [1000 2000])'   '(1111 2222)'
check "(map vec 5 colls)" '(map vector [1] [2] [3] [4] [5])'              '([1 2 3 4 5])'
check "(mapv + 4 colls)"  '(mapv + [1 2] [10 20] [100 200] [1000 2000])'  '[1111 2222]'
check "(mapcat 4 colls)"  '(mapcat list [1 2] [3 4] [5 6] [7 8])'         '(1 3 5 7 2 4 6 8)'
# list* 5+ args: spread the trailing seq.
check "(list* 1..5 tail)" '(list* 1 2 3 4 5 [6 7])'                       '(1 2 3 4 5 6 7)'
check "(list* 8 args)"    '(list* 1 2 3 4 5 6 7 [8 9])'                   '(1 2 3 4 5 6 7 8 9)'
# bit-and-not fold over 3+ args.
check "(bit-and-not 3 args)" '(bit-and-not 15 9 2)'                       '4'
# resolve 2-arg env form: a local named in env resolves to nil.
check "(resolve env local)"  "(resolve '{x nil} 'x)"                      'nil'

# --- array ctor 2-arg `(X-array size init-val-or-seq)` (D-446): a value init
#     fills, a sequential init copies (rest default). ---
check "(int-array n val)" '(vec (int-array 5 7))'                         '[7 7 7 7 7]'
check "(int-array n seq)" '(vec (int-array 5 [1 2 3]))'                   '[1 2 3 0 0]'
check "(double-array n)"  '(vec (double-array 3 1.5))'                    '[1.5 1.5 1.5]'
check "(byte-array n seq)" '(vec (byte-array 3 [1 2]))'                   '[1 2 0]'
check "(char-array n ch)" '(int (aget (char-array 3 (char 120)) 1))'     '120'
# AD-036 pin: byte/short/char-array fill a NUMBER init (clj throws on the JVM
# Numbers overload; cljw arrays are type-erased so they fill uniformly).
check "AD-036 (byte-array n num)" '(vec (byte-array 3 65))'              '[65 65 65]'
check "AD-036 (char-array n int)" '(int (aget (char-array 3 65) 0))'    '65'

# `bytes?` is true only for a byte array (clj parity; arrays carry their
# element kind since ADR-0204, which retired the over-broad AD-051).
check "(bytes? byte-array)"   '(bytes? (byte-array 3))'    'true'
check "(bytes? int-array)"    '(bytes? (int-array 3))'     'false'
check "(bytes? object-array)" '(bytes? (object-array 0))'  'false'


# --- multi-dim aget/aset (D-446 close-out): the variadic forms walk nested
#     arrays exactly as clj's `(apply aget (aget a i) idxs)` recursion. The
#     generic aget/aset cases are clj-byte-matched (arity_envelopes corpus). ---
check "(aget a i j)"        '(let [a (make-array Long 2 3)] (aset a 0 1 42) (aget a 0 1))'    '42'
check "(aset a i j k v)"    '(let [b (make-array Long 2 2 2)] (aset b 1 0 1 9) (aget b 1 0 1))' '9'
check "(aget oob catchable)" '(let [a (make-array Long 2 3)] (try (aget a 9 0) (catch Throwable t :oob)))' ':oob'
# AD-019 pin: make-array ignores its class argument and builds an object
# array, and the typed aset-* multidim arms store into it (clj throws
# IllegalArgumentException on a boxed array; cljw has no Class to key on).
check "AD-019 (aset-long a i j v)"   '(let [b (make-array Long 2 2 2)] (aset-long b 0 1 1 5) (aget b 0 1 1))' '5'
check "AD-019 (aset-double a i j v)" '(let [c (make-array Double 2 2)] (aset-double c 1 1 2.5) (aget c 1 1))' '2.5'
check "AD-019 (aset-int a i j v)"    '(let [c (make-array Long 2 2)] (aset-int c 0 0 3) (aget c 0 0))' '3'

echo "pass=$pass fail=$fail"
if [[ $fail -gt 0 ]]; then exit 1; fi
