#!/usr/bin/env bash
# test/e2e/phase16_gc_torture.sh — GC torture regression guard (D-250 / D-251).
#
# Runs representative programs under CLJW_GC_TORTURE=1 (force a stop-the-world
# collect at every VM back-edge poll, post-bootstrap) and asserts they still
# produce the correct value. This locks the two GC fixes the torture mode
# surfaced:
#   - Function.header forced to offset 0 (D-251 layout class) — without it the
#     mark walk OOB-crashes on every .clj fn.
#   - the .fn_val GC trace that marks closure_bindings (D-251 rooting class) —
#     without it a fn's captured GC values are swept under collect.
#
# Scope: only the cases that are torture-clean today. The remaining D-251
# rooting gaps (transducer/interpose seq intermediates, protocol-machinery
# values) are NOT yet covered — adding them here is the close-out test for
# those fixes.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# Every program runs with a collect forced at every back-edge poll.
export CLJW_GC_TORTURE=1

assert_eq 'arith'        "$("$BIN" -e '(+ 1 2)')"                                              '3'
assert_eq 'sum_squares'  "$("$BIN" -e '(reduce + (map (fn [x] (* x x)) (range 1 100)))')"      '328350'
# Frame nil-init regression (the reverted O-005): a deep recursion dirties the
# high call-frame stack slots, then a shallow fn whose body has a nested fn*
# runs — if a fn ever leaves its `[frame_size..MAX_LOCALS)` tail uninitialised,
# the VM publishes that stack garbage as a GC root and a torture collect traces
# it → SIGSEGV. Deterministic catcher for that whole class.
assert_eq 'nested_deep'  "$("$BIN" -e '(do (defn dp [n] (if (zero? n) (reduce + (map (fn [a] (* a a)) (range 1 50))) (+ 1 (dp (dec n))))) (dp 40))')" '40465'
# ADR-0131 in-VM call-frame stack gate: a HEAP value (vector `v`) held in a
# LOCAL across a NON-TAIL recursive call. nested_deep allocates only at the
# base; THIS allocates per frame AND keeps it live across the recursive op_call,
# so a flattened frame that fails to GC-root its own locals window gets `v` swept
# mid-recursion → `(first v)` after the call reads freed memory (the O-005 UAF
# class, now for the shared-arena locals). fib proves nothing here (fixnum-only).
# dp(n) = (first [n n n]) + dp(n-1) = n + dp(n-1) = sum(1..200) = 20100.
assert_eq 'frame_local_alloc' "$("$BIN" -e '(do (defn dp [n] (if (zero? n) 0 (let [v [n n n]] (+ (first v) (dp (dec n)))))) (dp 200))')" '20100'
assert_eq 'sqrt'         "$("$BIN" -e '(do (require (quote [clojure.math])) (clojure.math/sqrt 16))')" '4.0'
assert_eq 'filter_count' "$("$BIN" -e '(count (filter even? (range 1 200)))')"                 '99'
# closure capturing a GC vector — exercises the .fn_val closure_bindings trace.
assert_eq 'closure_vec'  "$("$BIN" -e '(let [x [1 2 3]] ((fn [] (reduce + x))))')"             '6'
# nested closure capturing a captured value.
assert_eq 'closure_nest' "$("$BIN" -e '(let [a 10] (let [f (fn [b] (+ a b))] (f 5)))')"        '15'
# map building into a persistent map (HAMT nodes survive repeated collects).
assert_eq 'into_map'     "$("$BIN" -e '(count (into {} (map (fn [i] [i (* i i)]) (range 1 50))))')" '49'
# reduce accumulator rooted across the reducing-fn eval (ADR-0094 / D-251).
assert_eq 'reduce_sum'   "$("$BIN" -e '(reduce + (range 1 101))')"                                  '5050'
assert_eq 'mapv_lit'     "$("$BIN" -e '(mapv inc [10 20 30])')"                                     '[11 21 31]'
assert_eq 'frequencies'  "$("$BIN" -e '(frequencies [1 1 2 3 3 3])')"                               '{1 2, 2 1, 3 3}'
# reduce over a vector source (the .vector fast path's racc rooting).
assert_eq 'reduce_vec'   "$("$BIN" -e '(reduce + [1 2 3 4 5 6 7 8 9 10])')"                         '55'
# .clj reducing-fn closure rooted across iterations (f-slot) over a chunked
# range source (coll rooted across the first force) — D-251 / ADR-0094.
assert_eq 'reduce_clos'  "$("$BIN" -e '(count (reduce (fn [a x] (conj a (inc x))) [] (range 1 150)))')" '149'
assert_eq 'vec_range'    "$("$BIN" -e '(count (vec (range 1 1000)))')"                              '999'

# ADR-0095 Class 2a — executing-chunk LITERAL constants rooted via
# EvalFrame.constants. A bare string literal is reachable only through the
# chunk's constant pool until op_const loads it; without the pool as a root a
# pre-load torture collect swept it (`"hello"` -> garbage bytes).
assert_eq 'str_literal'  "$("$BIN" -e '(count "hello")')"                                           '5'
assert_eq 'str_concat'   "$("$BIN" -e '(apply str ["a" "b" "c"])')"                                 '"abc"'
# interpose's literal separator (a constant) survives the reduce realiser.
assert_eq 'interpose'    "$("$BIN" -e '(apply str (interpose "," (map str (range 1 30))))')"        '"1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29"'
# ADR-0095 Class 1 — persistent-waypoint re-clear: the source range captured in
# a map lazy-seq thunk's closure stays marked across repeated collects (the
# thunk fn's stale bit no longer blocks the closure re-trace).
assert_eq 'vec_lazymap'  "$("$BIN" -e '(count (vec (map inc (range 1 200))))')"                     '199'
assert_eq 'into_lazymap' "$("$BIN" -e '(count (into [] (map inc (range 1 200))))')"                 '199'
# map producing pair vectors into a hash-map under torture (HAMT + the pair
# vectors survive the reduce realiser).
assert_eq 'into_pairs'   "$("$BIN" -e '(count (into {} (map (fn [x] [x (* x x)]) (range 1 50))))')" '49'
# ADR-0095 Alt D — a DORMANT fn's chunk LITERAL constant rooted via traceFunction
# (the isGcManaged membrane makes that constant walk safe). `g` is reachable via
# its var but not executing between mapv calls; without the trace its "n=" literal
# is swept and the next call loads a dangling pointer.
assert_eq 'dormant_lit'  "$("$BIN" -e '(do (defn g [x] (str "n=" x)) (apply str (mapv g (range 1 20))))')" '"n=1n=2n=3n=4n=5n=6n=7n=8n=9n=10n=11n=12n=13n=14n=15n=16n=17n=18n=19"'
# keyword/symbol constants (gpa-interned, non-GC) are filtered by isGcManaged, so
# a fn whose body references a keyword is torture-clean.
assert_eq 'kw_const'     "$("$BIN" -e '(count (filter (fn [m] (:keep m)) [{:keep true} {:keep false} {:keep true}]))')" '2'
# D-252 C9 — the CLI result-print path realises a lazy seq (forcing thunks
# re-enters the VM); `result` is pinned across printResult so a collect mid-print
# does not sweep the seq + its source (was a hang/UAF, exit 124/garbage).
assert_eq 'print_lazy'   "$("$BIN" -e '(filter even? (range 1 20))')"                               '(2 4 6 8 10 12 14 16 18)'
# D-252 C2/C3 — every?/some? root the seq cursor across the predicate's reentrant
# eval (EvalFrame, like reduceFn); over a LAZY-MAP source the cursor was swept.
assert_eq 'some_lazy'    "$("$BIN" -e '(some (fn [x] (when (> x 150) x)) (map inc (range 1 200)))')" '151'
assert_eq 'every_lazy'   "$("$BIN" -e '(every? (fn [x] (< x 500)) (map inc (range 1 200)))')"        'true'
# D-252 C6 — clojure.walk rebuild fns (list/vector/set/array_map) root the
# in-progress accumulator + source across the inner fn's reentrant eval; under
# torture the accumulator was swept (set -> #{5 nil}, vector -> @memcpy panic).
assert_eq 'walk_vec'     "$("$BIN" -e '(clojure.walk/postwalk (fn [x] (if (number? x) (inc x) x)) [1 2 3 [4 5 [6 7]]])')" '[2 3 4 [5 6 [7 8]]]'
assert_eq 'walk_map'     "$("$BIN" -e '(clojure.walk/postwalk (fn [x] (if (number? x) (inc x) x)) {:a 1 :b 2 :c 3})')" '{:a 2, :b 3, :c 4}'
# walk over a >8-key map (hash_map/HAMT) — the reentrant rebuildHashMap rebuild
# must keep its accumulator + entries rooted (C6) across the per-entry callback.
assert_eq 'walk_hashmap' "$("$BIN" -e '(count (clojure.walk/postwalk (fn [x] (if (number? x) (inc x) x)) (into {} (map (fn [i] [(keyword (str i)) i]) (range 40)))))')" '40'
assert_eq 'walk_set'     "$("$BIN" -e '(count (clojure.walk/postwalk (fn [x] (if (number? x) (inc x) x)) (set (range 1 60))))')" '59'
# D-253 cluster (a) — atom notifyWatches roots the atom + watches map + key cursor
# across the watch fn's reentrant eval (a nested swap! re-enters the VM); the
# cursor was swept -> rest(garbage) -> next get nil -> "Cannot call nil".
assert_eq 'atom_watch'   "$("$BIN" -e '(let [log (atom []) a (atom 0)] (add-watch a :k (fn [k r o n] (swap! log conj [k o n]))) (swap! a inc) (reset! a 10) @log)')" '[[:k 0 1] [:k 1 10]]'
# D-253 C7 — .multi_fn now has a GC trace marking its 8 Value fields (above all the
# method_table); it is gc.alloc'd, so without the trace its method table was swept
# (a missing-trace gap, not a reentrant-rooting one) -> "No method for dispatch value".
assert_eq 'multimethod'  "$("$BIN" -e '(do (defmulti ar :shape) (defmethod ar :circle [s] (* 3 (:r s))) (defmethod ar :square [s] (* (:side s) (:side s))) (mapv ar [{:shape :circle :r 2} {:shape :square :side 3} {:shape :circle :r 5}]))')" '[6 9 15]'
# print-method is itself a defmulti — pr-str under torture exercises the trace.
assert_eq 'print_method' "$("$BIN" -e '(mapv pr-str [1 :a "s" [1 2] {:k 3}])')" '["1" ":a" "\"s\"" "[1 2]" "{:k 3}"]'
# D-253 cluster (b) — printResult's deep-realize walk (realizeSeqWalk) roots its
# cursor + the gpa accumulator of realized items across seq/first/rest + the
# recursive deepRealize. A NESTED lazy seq (partition returns lazy-seqs of
# lazy-takes) corrupted under torture (`((1 (1 (1 ...` garbage cons); the C9
# result-pin roots only the outer Value, not the walk's own intermediates.
assert_eq 'print_nested' "$("$BIN" -e '(partition 2 (range 1 10))')"                                '((1 2) (3 4) (5 6) (7 8))'
assert_eq 'print_lazlaz' "$("$BIN" -e '(map (fn [x] (range 1 x)) (range 2 5))')"                    '((1) (1 2) (1 2 3))'
# IRef var watches — `Var.watches` is reachable for the collector ONLY via the
# ns_vars root walk (a var_ref is GC-membrane-filtered), so a torture collect mid
# alter-var-root would sweep the watch fn without the new `pending_watches` yield.
assert_eq 'var_watch'    "$("$BIN" -e '(do (def x 0) (def log (atom [])) (add-watch (var x) :k (fn [k r o n] (swap! log conj n))) (dotimes [_ 8] (alter-var-root (var x) inc)) @log)')" '[1 2 3 4 5 6 7 8]'
# D-253 macroexpand — the analyzer's valueToForm (Value->Form round-trip of a
# macro expansion) roots its seq cursor / source across the recursive conversion
# + lazy realization (a macro's `(seq (concat …))` syntax-quote). Without it a
# torture collect mid-expansion swept the cursor -> garbage form (with-redefs
# emitted `(var <list>)` -> an analysis-time error).
assert_eq 'macroexpand'  "$("$BIN" -e '(do (def ^:dynamic *wv* 1) (with-redefs [*wv* 5] (+ *wv* *wv*)))')" '10'
# D-244 #4 scoping — the forced torture collect fires only on the MAIN
# (unregistered) thread, so a future/agent WORKER's own STW collect can no longer
# self-deadlock or miss the main's roots. A MAIN-thread collect parks the workers
# and walks the complete root set, so real-threading is torture-clean from the
# main driver. (Was: future-with-work hung exit 124, mapv-of-futures crashed 134.)
assert_eq 'future_work'  "$("$BIN" -e '(let [f (future (reduce + (range 1 100)))] @f)')"             '4950'
assert_eq 'futures_map'  "$("$BIN" -e '(let [fs (mapv (fn [i] (future (* i i))) (range 1 5))] (mapv deref fs))')" '[1 4 9 16]'
assert_eq 'pmap_torture' "$("$BIN" -e '(pmap inc (range 1 8))')"                                     '(2 3 4 5 6 7 8)'
# D-244 #4 rendezvous — a drainer running a tiny action finishes + UNREGISTERS
# before it ever parks, so stopWorld's once-snapshotted target was never reached
# and the MAIN-thread torture collect hung (124). stopWorld now recomputes the
# target each wake + the leaving worker wakes it (root_set.noteWorkerLeft).
assert_eq 'agent_send'   "$("$BIN" -e '(let [a (agent 0)] (send a inc) (await a) @a)')"               '1'
assert_eq 'agent_drain'  "$("$BIN" -e '(let [a (agent 0)] (dotimes [_ 20] (send a inc)) (await a) @a)')" '20'
assert_eq 'agent_conj'   "$("$BIN" -e '(let [a (agent [])] (send a conj 1) (send a conj 2) (await a) @a)')" '[1 2]'
assert_eq 'agent_sendoff' "$("$BIN" -e '(let [a (agent 0)] (send-off a + 5) (await a) @a)')"          '5'
# D-244 #4 blocking-safepoint — `delay.force` runs the thunk (arbitrary eval)
# under the once-lock, so the COLLECTING main thread holds the lock across a
# torture collect while a future worker blocks on it. A plain block leaves the
# worker off any safepoint -> stopWorld waits for it forever (hang 124).
# safepoint.lockMutexAtSafepoint counts the blocked worker parked.
assert_eq 'delay_concurrent' "$("$BIN" -e '(let [n (atom 0) d (delay (swap! n inc))] (future (deref d)) (deref d) @n)')" '1'

# ---------------------------------------------------------------------------
# D-244 #4 — ALLOC-driven torture (CLJW_GC_TORTURE_ALLOC=1 forces a STW collect
# inside EVERY gc.alloc). Stricter than the back-edge torture above: it catches a
# multi-alloc collection BUILDER that holds an intermediate NODE (*TailNode /
# *HamtNode / *Cons — NOT a Value) in an unrooted Zig local across the next
# alloc. The fabrication no-collect region (ADR-0150) brackets each builder so a
# mid-builder collect is DEFERRED (correct under F-006 non-moving mark-sweep).
#
# SCOPE: these are pure SYNCHRONOUS builders (no eval reentry). The complementary
# class — a collect during an eval-REENTRANT lazy-seq realization / reduce over a
# RANGE source (e.g. `(into {} (map f (range N)))`) — is D-244 #4b, FIXED
# 2026-06-17: `range.seqChunk` left its `ChunkBuffer` unrooted across the tail
# `make` + `ChunkedCons` allocs, and `-take-eager` walked a seq into an untraced
# gpa `ArrayList` with an unrooted cursor — both now bracket the fabrication
# no-collect region. The #4b regression cases are the `#4b` block below.
#
# Probes are SMALL/EAGER (alloc-torture = O(allocs) full collects; large or
# lazy-seq realizations are deliberately avoided) and assert STRUCTURE, not
# set/map print order (AD-001). A missed builder bracket trips one of these →
# self-enforcing completeness guard.
assert_alloc() { local n="$1"; local g; g="$(CLJW_GC_TORTURE=0 CLJW_GC_TORTURE_ALLOC=1 "$BIN" -e "$2" 2>&1)"; [[ "$g" == "$3" ]] || fail "alloc/$n: got '$g' want '$3'"; echo "PASS alloc/$n -> $3"; }

# vector — literal (fromSlice), conj fast path, the `vector`/`vec` builtins.
assert_alloc 'vec_literal'    '[1 2 3 4 5]'                                  '[1 2 3 4 5]'
assert_alloc 'conj_vec'       '(conj [1 2 3] 4)'                             '[1 2 3 4]'
assert_alloc 'vector_fn'      '(vector 1 2 3 4 5)'                           '[1 2 3 4 5]'
assert_alloc 'vec_list'       '(vec (list 1 2 3))'                           '[1 2 3]'
# list builder — `acc = consHeap(rt, x, acc)` cons-fold (the `list` builtin).
assert_alloc 'list_fn'        '(count (list 1 2 3 4 5))'                     '5'
# transient vector finalize (into [] -> persistent! -> fromSlice).
assert_alloc 'into_vec'       '(into [] (range 5))'                          '[0 1 2 3 4]'
# conj tail-full -> root push (crossing the 32-boundary in the tail path).
assert_alloc 'conj_tailfull'  '(count (reduce conj [] (range 35)))'         '35'
# fromSlice multi-level trie: n > 64 forces the `level_nodes` tower loop.
assert_alloc 'fromslice_tower' '(nth (vec (range 70)) 69)'                  '69'
# vector assoc (trie copy-path) + pop (leaf-pull multi-alloc path).
assert_alloc 'vec_assoc'      '(nth (assoc (vec (range 33)) 10 99) 10)'     '99'
assert_alloc 'vec_pop'        '(peek (pop (vec (range 33))))'               '31'
# sets — assert count + membership (print order is AD-001).
assert_alloc 'conj_set'       '(count (conj #{1 2} 3))'                      '3'
assert_alloc 'set_member'     '(contains? (conj #{1 2} 3) 3)'               'true'
assert_alloc 'set_promote'    '(count (into #{} (range 12)))'              '12'
# maps — array-map fast path + HAMT promote (> 8 keys), count + lookup.
assert_alloc 'hashmap_fn'     '(get (hash-map :a 1 :b 2) :b)'               '2'
assert_alloc 'map_literal'    '(get {:a 1 :b 2 :c 3} :c)'                   '3'
assert_alloc 'map_promote'    '(count (into {} [[1 1] [2 2] [3 3] [4 4] [5 5] [6 6] [7 7] [8 8] [9 9] [10 10]]))' '10'
# json read-str fabricates an UNPUBLISHED result tree (recursive jsonToCw +
# fromSlice/fromLiteralPairs buffers, unrooted across nested allocs); the whole
# parse is bracketed by readStrFn's fabrication region. Without it a mid-parse
# alloc-collect swept the in-progress "users" vector -> count 0 (D-519's
# alloc-boundary auto-collect EXPOSED this latent gap; surfaced as the json_parse
# bench's intermittent 19000-vs-20000, deterministic 0 under alloc-torture).
assert_alloc 'json_nested'    '(do (require (quote [clojure.data.json :as json])) (count (get (json/read-str (json/write-str {:users (vec (map (fn [i] {:id i :tags ["a" "b"]}) (range 20)))})) "users")))' '20'

# D-244 #4b — eval-REENTRANT lazy-seq realization / reduce over a RANGE source.
# Before the fix these returned 1 / nil-errors under alloc-torture (the range
# ChunkBuffer / -take-eager cursor were swept mid-realization). Small N (alloc
# torture = O(allocs) full collects); assert count/structure, not order (AD-001).
assert_alloc '4b_into_map_range'  '(count (into {} (map (fn [i] [i i]) (range 20))))'  '20'
assert_alloc '4b_reduce_map_inc'  '(reduce + 0 (map inc (range 20)))'                  '210'
assert_alloc '4b_filter_range'    '(reduce + 0 (filter odd? (range 20)))'              '100'
assert_alloc '4b_take_range'      '(reduce + 0 (take 5 (range 20)))'                   '10'
assert_alloc '4b_into_vec_lazy'   '(count (into [] (map inc (range 40))))'             '40'
assert_alloc '4b_multichunk'      '(count (into {} (map (fn [i] [i i]) (range 50))))'  '50'
assert_alloc '4b_take_multichunk' '(reduce + 0 (take 40 (range 100)))'                 '780'

echo "ALL phase16_gc_torture PASS"
