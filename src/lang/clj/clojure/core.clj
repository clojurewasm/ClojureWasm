;; ClojureWasm Stage-1 prologue.
;;
;; Loaded by `src/lang/bootstrap.zig::loadCore` after
;; `primitive.registerAll` and `macro_transforms.registerInto`. The
;; head form is `(ns clojure.core (:refer-clojure))` per ADR-0035 D1
;; — the analyzer special form switches into clojure.core (creating
;; the ns at boot via `Env.init`, idempotent here) and honours
;; `:refer-clojure` (a no-op when we ARE clojure.core; kept for
;; surface-uniformity with the other bootstrap files).

(ns clojure.core (:refer-clojure))

(def not (fn* [x] (if x false true)))

;; `*warn-on-reflection*` — a JVM compiler flag for reflective interop calls.
;; cljw resolves interop without reflection, so this is a no-op flag: defined so
;; code that references / `binding`s / `set!`s it loads (real libs + the upstream
;; suites toggle it). D-232.
(def ^:dynamic *warn-on-reflection* false)

;; `(list & items)` — construct a list of the args. The variadic
;; rest-binding yields a `.list` for ≥1 arg, but nil for zero args
;; (`& xs` binds nil when empty, matching JVM `((fn [& xs] xs))` → nil).
;; `(list)` must be `()` (JVM `PersistentList/EMPTY`), so map the empty
;; case to the quoted empty list `'()` (the interned empty value, D-164).
(def list (fn* [& xs] (if xs xs '())))

;; `(-seq-or-empty coll)` — a seq view that is `()` (not nil) when empty.
;; The eager seq fns (sort / distinct / dedupe / map-indexed / …) build a
;; vector then return a SEQ; JVM yields `()` for an empty result, so the
;; bare `(seq v)` (nil for empty) is lifted here (D-164 / clj-parity C1,
;; one shared mechanism per F-011).
(def -seq-or-empty (fn* [coll] (or (seq coll) '())))

;; ----------------------------------------------------------------
;; Phase 6.16.a-3.2 — eager higher-order surface (ADR-0033 D6 + v5 §5.2).
;;
;; Each surface fn delegates to its Zig leaf (`-foo-eager`) via the
;; `-name` Pattern B2 contract from ADR-0033 D4. The transducer 1-arg
;; arities (`(map f)` returning an xform) + `transduce`/`into`-xform/
;; `completing`/`cat`/`halt-when` LANDED 2026-05-30 (D-177, the multi-
;; arity prereq D-070 is discharged) in the transducer section below;
;; these `-foo-eager` forms are the eager collection arities. The lazy
;; `sequence`/`eduction` pull surface is the only remaining gap (D-160,
;; needs a push→pull transducer bridge).
;; ----------------------------------------------------------------

;; map / filter / keep / remove / drop are LAZY (ADR-0054 cycle 2/3):
;; each wraps its step in `lazy-seq` so it composes with infinite
;; producers (`(first (map inc (iterate inc 0)))` → 1, no hang;
;; `(first (drop 100 (range)))` → 100). `take` stays bounded-eager (it
;; realizes only N, so it already terminates on an infinite source).
;; The `-*-eager` map/filter/keep/remove/drop leaves are deleted.
;; `map` — 1/2/3-coll. Multi-coll walks colls in parallel, stops at the
;; shortest (D-134). N-coll variadic (`& colls`) deferred: it needs
;; every?/identity which are later core.clj defns (def-order; fn-body
;; symbols resolve at def time), so it would need a primitive-only seq-all.
(def map
  (fn* ([f]
        ;; transducer arity: (map f) returns a transducer
        (fn* [rf]
          (fn* ([] (rf))
               ([result] (rf result))
               ([result input] (rf result (f input)))
               ;; multi-input arity: a multi-coll `sequence` steps the xform
               ;; with one item per source — `map` is the only core transducer
               ;; that consumes them (D-160 3-arg residual). A single-input
               ;; transducer placed first stays 2-arg → arity error (clj parity).
               ([result input & inputs] (rf result (apply f input inputs))))))
       ([f coll]
        ;; PERF: when the source is chunked (range seq, chunked map/filter),
        ;; transform a whole 32-chunk per thunk so the lazy-seq machinery is
        ;; amortised 32x (JVM chunk-cons shape) [refs: O-004, D-163]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (if (chunked-seq? s)
                (let [size (-chunk-count s)
                      b (chunk-buffer size)]
                  (loop [i 0]
                    (when (< i size)
                      (chunk-append b (f (-chunk-nth s i)))
                      (recur (inc i))))
                  (chunk-cons b (map f (chunk-rest s))))
                (cons (f (first s)) (map f (rest s))))
              nil))))
       ([f c1 c2]
        (lazy-seq
          (let [s1 (seq c1) s2 (seq c2)]
            (if (and s1 s2)
              (cons (f (first s1) (first s2)) (map f (rest s1) (rest s2)))
              nil))))
       ([f c1 c2 c3]
        (lazy-seq
          (let [s1 (seq c1) s2 (seq c2) s3 (seq c3)]
            (if (and s1 s2 s3)
              (cons (f (first s1) (first s2) (first s3))
                    (map f (rest s1) (rest s2) (rest s3)))
              nil))))))
(def filter
  (fn* ([pred]
        ;; transducer arity
        (fn* [rf]
          (fn* ([] (rf))
               ([result] (rf result))
               ([result input] (if (pred input) (rf result input) result)))))
       ([pred coll]
        ;; PERF: chunk-preserving filter — drop within a 32-chunk, emit a
        ;; (possibly shorter) chunk; empty chunks are skipped by chunk-cons
        ;; [refs: O-004, D-163]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (if (chunked-seq? s)
                (let [size (-chunk-count s)
                      b (chunk-buffer size)]
                  (loop [i 0]
                    (when (< i size)
                      (let [v (-chunk-nth s i)]
                        (when (pred v) (chunk-append b v)))
                      (recur (inc i))))
                  (chunk-cons b (filter pred (chunk-rest s))))
                (let [v (first s)]
                  (if (pred v)
                    (cons v (filter pred (rest s)))
                    (filter pred (rest s)))))
              nil))))))
(def take
  (fn* ([n]
        ;; transducer arity: stateful (counts down n), ensure-reduced to stop
        (fn* [rf]
          (let [nv (volatile! n)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input]
                  (let [m @nv
                        nm (vswap! nv dec)
                        result (if (> m 0) (rf result input) result)]
                    (if (not (> nm 0)) (ensure-reduced result) result)))))))
       ([n coll] (-take-eager n coll))))
(def drop
  (fn* ([n]
        ;; transducer arity: stateful (skips the first n inputs)
        (fn* [rf]
          (let [nv (volatile! n)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input]
                  (let [m @nv]
                    (vswap! nv dec)
                    (if (> m 0) result (rf result input))))))))
       ([n coll]
        (lazy-seq
          (let [s (seq coll)]
            (if (and (> n 0) s)
              (drop (dec n) (rest s))
              s))))))
;; nthnext/nthrest: [coll n] arg order (JVM clojure.core). The sequential
;; destructure `& rest` lowering (D-076) emits (nthnext g idx). nthnext
;; seqs (nil when empty); nthrest returns the rest coll as-is.
(def nthnext (fn* [coll n] (seq (drop n coll))))
(def nthrest (fn* [coll n] (drop n coll)))
(def keep
  (fn* ([f]
        ;; transducer arity: keeps the non-nil (f input)
        (fn* [rf]
          (fn* ([] (rf))
               ([result] (rf result))
               ([result input] (let [v (f input)] (if (nil? v) result (rf result v)))))))
       ([f coll]
        ;; PERF: chunk-preserving keep (drops nil (f x) within a chunk)
        ;; [refs: O-004, D-163]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (if (chunked-seq? s)
                (let [size (-chunk-count s)
                      b (chunk-buffer size)]
                  (loop [i 0]
                    (when (< i size)
                      (let [r (f (-chunk-nth s i))]
                        (when (not (nil? r)) (chunk-append b r)))
                      (recur (inc i))))
                  (chunk-cons b (keep f (chunk-rest s))))
                (let [r (f (first s))]
                  (if (nil? r) (keep f (rest s)) (cons r (keep f (rest s))))))
              nil))))))
(def remove
  (fn* ([pred]
        ;; transducer arity: drops inputs where pred is truthy
        (fn* [rf]
          (fn* ([] (rf))
               ([result] (rf result))
               ([result input] (if (pred input) result (rf result input))))))
       ([pred coll] (filter (fn* [x] (not (pred x))) coll))))

;; ----------------------------------------------------------------
;; Transducer drivers (the foundation — reduced?/unreduced/reduce —
;; already exists). `cat` + the stateful transducers (take/drop/
;; dedupe/distinct/partition-all) land in later cycles.
;; ----------------------------------------------------------------

;; `(completing f)` / `(completing f cf)` — adapt a 2-arg fn into a
;; reducing fn with 0-arg init `(f)`, 1-arg completion (`cf`, default
;; identity), and 2-arg step `(f x y)`.
(def completing
  (fn* ([f] (fn* ([] (f)) ([x] x) ([x y] (f x y))))
       ([f cf] (fn* ([] (f)) ([x] (cf x)) ([x y] (f x y))))))

;; `(transduce xform f coll)` / `(transduce xform f init coll)` — reduce
;; `coll` through the transformed reducing fn, then call its 1-arg
;; completion. `(f)` supplies the init when omitted.
(def transduce
  (fn* ([xform f coll] (transduce xform f (f) coll))
       ([xform f init coll]
        (let [rf (xform f)
              ret (reduce rf init coll)]
          (rf (unreduced ret))))))

;; `-editable?` — can `coll` be built via `transient` + `persistent!`?
;; Mirrors JVM IEditableCollection: hash-based vectors, maps, sets. A
;; nil or list target is excluded — `(into nil xs)` / `(into () xs)`
;; build a list by prepend, which the transient path would not reproduce.
;; Sorted maps/sets are also excluded: they have no transient (and JVM's
;; sorted collections are not IEditableCollection either), so they keep
;; the persistent-conj path.
(def -editable?
  (fn* [coll]
    (if (sorted? coll)
      false
      (or (vector? coll) (map? coll) (set? coll)))))

;; `(into to from)` conj every item of `from` onto `to`; `(into to xform
;; from)` does so through the transducer `xform`. Defined here (Layer 2)
;; over reduce/transduce — supersedes the rt/into eager primitive (which
;; had no other Zig callers). `conj`'s 1-arg completion arity makes the
;; bare-`conj` reducing fn work for the transduce path.
;; PERF: editable targets build via a transient (O(n) persistent! over a flat buffer) vs N persistent conjs O(n log n) [refs: O-003, D-180]
(def into
  (fn* ([to from]
         (if (-editable? to)
           (persistent! (reduce conj! (transient to) from))
           (reduce conj to from)))
       ([to xform from]
         (if (-editable? to)
           (let [rf (fn* ([tc] (persistent! tc))
                         ([tc x] (conj! tc x)))]
             (transduce xform rf (transient to) from))
           (transduce xform conj to from)))))

;; `(-preserving-reduced rf)` wraps rf so that a Reduced result from an
;; INNER reduce (cat uses one) is double-wrapped — the outer reduce then
;; sees the early-stop instead of cat swallowing it.
(def -preserving-reduced
  (fn* [rf]
    (fn* [a b]
      (let [ret (rf a b)]
        (if (reduced? ret) (reduced ret) ret)))))

;; `cat` — a transducer that concatenates the contents of each input
;; (each input is itself reduced into the downstream rf).
(def cat
  (fn* [rf]
    (let [rrf (-preserving-reduced rf)]
      (fn* ([] (rf))
           ([result] (rf result))
           ([result input] (reduce rrf result input))))))

;; `(halt-when pred)` / `(halt-when pred retf)` — a transducer that aborts
;; the whole transduction when an input matches `pred`, yielding that input
;; (or `(retf (rf result) input)` when `retf` is supplied). The halt value
;; rides through the 1-arg completion inside a qualified-keyword sentinel
;; map so a normal accumulated map result is not mistaken for a halt.
(def halt-when
  (fn* ([pred] (halt-when pred nil))
       ([pred retf]
        (fn* [rf]
          (fn* ([] (rf))
               ([result]
                (if (if (map? result) (contains? result :cljw.core/halt) false)
                  (get result :cljw.core/halt)
                  (rf result)))
               ([result input]
                (if (pred input)
                  (reduced {:cljw.core/halt (if retf (retf (rf result) input) input)})
                  (rf result input))))))))

;; D-160 push→pull transducer bridge. JVM builds `sequence`/`eduction` on
;; `TransformerIterator` (a buffering java.util.Iterator); cljw has no
;; Iterator protocol, so the bridge is pure `.clj` in cljw's lazy-seq idiom
;; (DIVERGENCE D1): step the source through the transducer's reducing fn —
;; a buffering rf that conj's each emitted output into a volatile vector —
;; and drain that buffer lazily. `xf` is `(xform rf)` created ONCE so
;; stateful xforms (`take`/`partition-all`) keep their volatile state across
;; the pull. An eager `(seq (into [] xform coll))` is forbidden: it would
;; hang on an infinite source where `sequence` must stay lazy.
;;
;; `-tx-seq-pump` recurses through its own top-level name (avoids a named
;; local fn — D-147). `done` flags that the completion arity has run (it may
;; flush a final buffered value, e.g. `partition-all`'s tail).
;; `buf` is the output vector (rf appends), `pos` the next index to emit, so
;; draining needs only `nth`/`count` (no `subvec`/`vec`, which are defined
;; later in this file and would be forward-refs at bootstrap).
;; `srcs` is a collection of N source colls (N≥1): on each fill cycle the
;; xform is stepped with one item per source (`(apply xf nil heads)`), stopping
;; when ANY source is exhausted (shortest-coll semantics, D-160 multi-coll).
;; The single-coll `sequence` is the N=1 case — one commonised bridge (F-011).
(def -tx-seq-pump
  (fn* [xf srcs buf pos done]
    (lazy-seq
      (let [b @buf p @pos]
        (if (< p (count b))
          (do (vreset! pos (inc p))
              (cons (nth b p) (-tx-seq-pump xf srcs buf pos done)))
          (if @done
            nil
            (do (vreset! buf []) (vreset! pos 0)
                (let [seqs (map seq srcs)]
                  (if (some nil? seqs)
                    (do (xf nil) (vreset! done true)
                        (-tx-seq-pump xf srcs buf pos done))
                    (let [r (apply xf nil (map first seqs))]
                      (if (reduced? r)
                        (do (xf nil) (vreset! done true)
                            (-tx-seq-pump xf srcs buf pos done))
                        (-tx-seq-pump xf (map rest seqs) buf pos done))))))))))))

;; Shared setup for the transducer arities: a buffering rf (each emitted
;; output conj'd into `buf`, stepped one source-tuple per lazy thunk) + the
;; volatiles the pump drains. Both the 2-arg and multi-coll `sequence` arms
;; route through here (F-011 — one source of the bridge wiring).
(def -tx-seq-run
  (fn* [xform srcs]
    (let [buf  (volatile! [])
          pos  (volatile! 0)
          done (volatile! false)
          rf   (fn* ([] nil) ([result] result) ([_ x] (vswap! buf conj x) nil))
          xf   (xform rf)]
      (-tx-seq-pump xf srcs buf pos done))))

;; `(sequence coll)` coerces to a seq (`(list)` empty, not the bare `()`
;; literal — cljw treats unquoted `()` as an empty invocation, D-188); the
;; 2-arg arm lazily applies the transducer via the bridge above. The multi-coll
;; arm (`(sequence xform c1 c2 …)`) steps the xform across tuples, stopping at
;; the shortest (D-160 residual); a single-input xform placed first is a 2-arg
;; step → arity error, matching clj's ArityException (not silently passed).
(def sequence
  (fn* ([coll] (or (seq coll) (list)))
       ([xform coll] (-tx-seq-run xform [coll]))
       ([xform coll & colls] (-tx-seq-run xform (cons coll colls)))))

;; ----------------------------------------------------------------
;; Pure Clojure HOF (no Zig leaf) — pattern A per ADR-0033 D3.
;; ----------------------------------------------------------------

;; `(constantly x)` returns a fn that ignores its args and yields x.
(def constantly
  (fn* [x] (fn* [& _] x)))

;; `(swap-vals! a f & args)` / `(reset-vals! a v)` return `[old new]`. cw v1 is
;; single-threaded, so capturing `@a` then applying `swap!`/`reset!` is the
;; atomic old↔new pair (no CAS retry needed; JVM returns the same shape).
(def swap-vals!
  (fn* [a f & args]
    (let [old @a]
      [old (apply swap! a f args)])))
(def reset-vals!
  (fn* [a v]
    (let [old @a]
      (reset! a v)
      [old v])))

;; `(pmap f & colls)` / `(pcalls & fns)` — clj's parallel map / parallel calls.
;; cw v1 is single-threaded, so these run SEQUENTIALLY: the RESULT is identical
;; to clj (pmap is "semantically like map"), only the parallelism is absent.
;; Real parallelism arrives with Phase-15 threading (D-224); the result contract
;; is final-form-correct now, so this is not a dropped-semantic stub.
(def pmap
  (fn* [f & colls] (apply map f colls)))
(def pcalls
  (fn* [& fns] (map (fn* [g] (g)) fns)))

;; `(dorun coll)` / `(dorun n coll)` — realize a (lazy) seq for side effects,
;; holding no head; returns nil. `(doall coll)` / `(doall n coll)` — same forcing
;; but returns the (now-realized) head. `if` (not `when`/`and`) keeps these
;; bootstrap-order-safe. The lazy-seq realization utilities (clojure.core).
(def dorun
  (fn* ([coll]
        (loop* [s (seq coll)]
          (if s (recur (next s)) nil)))
       ([n coll]
        (loop* [i n s (seq coll)]
          (if (if (pos? i) s nil) (recur (dec i) (next s)) nil)))))
(def doall
  (fn* ([coll] (dorun coll) coll)
       ([n coll] (dorun n coll) coll)))

;; `(complement pred)` returns a fn that negates pred's truthiness;
;; the returned fn is variadic (`[& args]`), matching JVM.
(def complement
  (fn* [pred] (fn* [& args] (not (apply pred args)))))

;; `(comparator pred)` builds a 3-way compare fn (-1 / 0 / 1) from a
;; 2-arg boolean `pred` (like `<`). Nested `if` (not `cond`) so it does
;; not depend on macro availability during bootstrap.
(def comparator
  (fn* [pred]
    (fn* [a b]
      (if (pred a b) -1 (if (pred b a) 1 0)))))

;; `(partial f & args)` partially applies f to the leading args.
;; The trailing arg list and the partial's captured args meet via
;; `(into (into [] args) more)` since cw v1 doesn't yet have
;; `concat`; the resulting vector goes through `apply`.
(def partial
  (fn* [f & args]
    (fn* [& more]
      (apply f (into (into [] args) more)))))

;; `comp` — variadic right-to-left function composition (D-134). `(comp)`
;; is identity; the N-ary case folds the 2-ary `comp` over the rest (comp
;; is associative). Composed fns take any arity via `& args` + `apply`.
(def comp
  (fn* ([] (fn* [x] x))
       ([f] f)
       ([f g] (fn* [& args] (f (apply g args))))
       ([f g & fs] (reduce comp (comp f g) fs))))

;; `juxt` — `((juxt f g …) & args)` yields `[(apply f args) (apply g args) …]`
;; (D-134: multi-fn + multi-arg; previously 2-fn / single-arg only).
(def juxt
  (fn* ([f] (fn* [& args] [(apply f args)]))
       ([f g] (fn* [& args] [(apply f args) (apply g args)]))
       ;; N-ary: build the result vector with reduce+conj (primitives —
       ;; `mapv` is a later core.clj defn, unresolvable at this def site).
       ([f g & fs]
        (fn* [& args]
          (reduce (fn* [acc h] (conj acc (apply h args)))
                  []
                  (cons f (cons g fs)))))))

;; `(some-fn p1 p2 …)` → a fn returning the first logical-true
;; `(pi & args)`, else the LAST pred's value (JVM `(or (p1 x) (p2 x) …)`
;; semantics: `((some-fn neg? even?) 3)`→false, not nil). `(every-pred …)`
;; → true iff every `(pi & args)` is logical-true, else false (D-134).
(def some-fn
  (fn* [& preds]
    (fn* [& args]
      (if (seq preds)
        (loop [ps preds]
          (let* [r (apply (first ps) args)]
            (if r
              r
              (if (seq (rest ps)) (recur (rest ps)) r))))
        nil))))

(def every-pred
  (fn* [& preds]
    (fn* [& args]
      (loop [ps preds]
        (if (seq ps)
          (if (apply (first ps) args) (recur (rest ps)) false)
          true)))))

;; `(trampoline f & args)` — call f; while the result is a fn, call it
;; (mutual-recursion without growing the stack). Self-recursive def.
(def trampoline
  (fn* ([f] (let* [ret (f)] (if (fn? ret) (trampoline ret) ret)))
       ([f & args] (trampoline (fn* [] (apply f args))))))

;; `(replace smap)` / `(replace smap coll)` — replace elements that are keys in
;; smap with their values. The 1-arg form is a transducer (`(map …)`); the 2-arg
;; form keeps vector in → vector out, seq in → lazy seq.
(def replace
  (fn* ([smap]
        (map (fn* [x] (if (contains? smap x) (get smap x) x))))
       ([smap coll]
        (if (vector? coll)
          (reduce (fn* [acc x] (conj acc (if (contains? smap x) (get smap x) x))) [] coll)
          (map (fn* [x] (if (contains? smap x) (get smap x) x)) coll)))))

;; `(not= x …)` — logical complement of `=`. `(fnext x)` = `(first (next x))`,
;; `(nnext x)` = `(next (next x))` — the first/next combinators. `(run! f
;; coll)` applies f to each element for side effects, returns nil (D-134).
(def not= (fn* [& args] (not (apply = args))))
(def fnext (fn* [x] (first (next x))))
(def nnext (fn* [x] (next (next x))))
(def run! (fn* [f coll] (reduce (fn* [_ x] (f x)) nil coll) nil))

;; Bit-position ops over the bitwise primitives (n = bit index, 0 = LSB).
;; JVM Numbers.java inlines these; cw v1 composes them in .clj per the
;; clj/zig split (bit-and/or/xor/not/shift-left are the Zig primitives).
(def bit-set   (fn* [x n] (bit-or x (bit-shift-left 1 n))))
(def bit-clear (fn* [x n] (bit-and x (bit-not (bit-shift-left 1 n)))))
(def bit-flip  (fn* [x n] (bit-xor x (bit-shift-left 1 n))))
(def bit-test  (fn* [x n] (not (zero? (bit-and x (bit-shift-left 1 n))))))
(def bit-and-not (fn* [x y] (bit-and x (bit-not y))))

;; `(peek coll)` / `(pop coll)` — stack ops. Vector: peek = last element,
;; pop = drop the last (returns a vector). List/seq: peek = first, pop =
;; rest. peek of empty is nil; pop of empty throws (JVM parity). D-134.
;; peek/pop are stack ops — defined ONLY on nil / list / vector (clj's
;; IPersistentStack). A non-stack seqable (string, lazy seq, range) throws in
;; clj (ClassCastException), so cljw must NOT silently fall through to first/
;; rest there (D-218). nil → nil for both (clj parity).
(def peek
  (fn* [coll]
    (if (nil? coll)
      nil
      (if (vector? coll)
        (if (pos? (count coll)) (nth coll (dec (count coll))) nil)
        (if (list? coll)
          (first coll)
          (throw (ex-info "Can't peek: not a stack (list, vector)" {:value coll})))))))
(def pop
  (fn* [coll]
    (if (nil? coll)
      nil
      (if (vector? coll)
        (if (pos? (count coll))
          (into [] (take (dec (count coll)) coll))
          (throw (ex-info "Can't pop empty vector" {})))
        (if (list? coll)
          (if (seq coll)
            (rest coll)
            (throw (ex-info "Can't pop empty list" {})))
          (throw (ex-info "Can't pop: not a stack (list, vector)" {:value coll})))))))

;; `(find m k)` — the map entry `[k v]` for key k if present, else nil
;; (distinguishes "absent" from "present with nil value" via contains?).
;; cw v1 represents the entry as a 2-vector (no distinct MapEntry type).
(def find
  (fn* [m k] (if (contains? m k) [k (get m k)] nil)))

;; `(subvec v start [end])` — the elements of v in [start, end) (end
;; defaults to (count v)) as a vector. cw v1 builds a fresh vector (O(n))
;; via take/drop rather than JVM's O(1) shared-structure view (D-134).
(def subvec
  (fn* ([v start] (into [] (drop start v)))
       ([v start end] (into [] (take (- end start) (drop start v))))))

;; `(bounded-count n coll)` — counts up to n elements (so it terminates on
;; infinite / expensive seqs). cw v1 always walks (≤ n steps); JVM short-
;; circuits to `(count coll)` for already-counted colls — a perf nicety,
;; same result for finite colls of size ≤ n (D-134).
(def bounded-count
  (fn* [n coll]
    (loop [c 0 s (seq coll)]
      (if (if s (< c n) false) (recur (inc c) (next s)) c))))

;; `(rand-nth coll)` — a uniformly random element of coll (which must be
;; indexed / counted). Empty coll → an out-of-bounds error (JVM parity).
(def rand-nth
  (fn* [coll] (nth coll (rand-int (count coll)))))

;; ----------------------------------------------------------------
;; Phase 6.16.b-3 helpers — used by clojure.set Group C (project /
;; rename / index / join). Pattern A composition; no Zig leaves.
;; ----------------------------------------------------------------

;; `(select-keys m ks)` — return a map containing only the keys in
;; `ks` that are present in `m`. JVM uses `find` to distinguish
;; "absent" from "nil-valued"; cw v1 uses `contains?` (same
;; semantic when nil-values are absent — Phase 7+ value-meta layer
;; adds `find`).
(def select-keys
  (fn* [m ks]
    (reduce (fn* [acc k]
              (if (contains? m k)
                (assoc acc k (get m k))
                acc))
            {}
            ks)))

;; `(merge & maps)` — right-most key wins. nil args are skipped.
;; Variadic via `[& maps]`; 0-arity returns nil (matches JVM).
(def merge
  (fn* [& maps]
    (if (= 0 (count maps))
      nil
      (reduce (fn* [acc m]
                (if (nil? m)
                  acc
                  (reduce (fn* [a k] (assoc a k (get m k)))
                          acc
                          (keys m))))
              (first maps)
              (rest maps)))))
;; `(merge-with f & maps)` — like merge, but a key present in more than
;; one map combines values via `(f existing new)` (D-134). nil maps skip.
(def merge-with
  (fn* [f & maps]
    (reduce (fn* [acc m]
              (if (nil? m)
                acc
                (reduce (fn* [a k]
                          (if (contains? a k)
                            (assoc a k (f (get a k) (get m k)))
                            (assoc a k (get m k))))
                        acc
                        (keys m))))
            {}
            maps)))

;; `(set coll)` — coerce a collection to a set. Duplicates collapse.
(def set
  (fn* [coll] (reduce conj #{} coll)))

;; `(distinct? x …)` — true iff no two arguments are equal (by value).
;; A set dedups by `=`, so distinct ⇔ the set keeps every element.
;; Defined after `set` (it folds args through it).
(def distinct?
  (fn* [& args] (= (count args) (count (set args)))))

;; ----------------------------------------------------------------
;; Phase 14 §9.16 row 14.13 — D-126 clojure.core daily-driver cluster.
;; Pattern A composition over reduce / get / assoc / first / next /
;; conj / into / apply. get-in/assoc-in/update-in walk a key path;
;; concat/mapcat are LAZY (ADR-0054 cycle 3): `-concat2` is the 2-coll
;; lazy-cons primitive both fold over, so they compose with infinite
;; producers (`(take 5 (concat [1 2] (range)))`).
;; ----------------------------------------------------------------

;; `(get-in m ks)` / `(get-in m ks not-found)` — walk the key path `ks`
;; through nested associatives. The 3-arity returns `not-found` when any step
;; is absent, distinguishing it from a present nil via a fresh-identity
;; sentinel (clj's `lookup-sentinel`): `(get m k sentinel)` yields the sentinel
;; only when `k` is truly absent.
(def get-in
  (fn* ([m ks] (reduce get m ks))
       ([m ks not-found]
        (let [sentinel (list '::get-in-sentinel)]
          (loop [m m ks (seq ks)]
            (if ks
              (let [v (get m (first ks) sentinel)]
                (if (identical? sentinel v)
                  not-found
                  (recur v (next ks))))
              m))))))

;; `(assoc-in m ks v)` — assoc `v` at the nested path `ks`, creating
;; intermediate maps as needed. `next` yields nil at the final key.
(def assoc-in
  (fn* [m ks v]
    (let [k (first ks) nks (next ks)]
      (if nks
        (assoc m k (assoc-in (get m k) nks v))
        (assoc m k v)))))

;; `(update-in m ks f & args)` — apply `f` (with trailing `args`) to
;; the value at the nested path `ks`. Recursive descent like assoc-in;
;; the leaf calls `(apply f old args)`.
(def update-in
  (fn* [m ks f & args]
    (let [k (first ks) nks (next ks)]
      (if nks
        (assoc m k (apply update-in (into [(get m k) nks f] args)))
        (assoc m k (apply f (into [(get m k)] args)))))))

;; `(-concat2 x y)` — lazy catenation of two seqables. Walks `x`
;; element-by-element under `lazy-seq`, then hands off to `(seq y)`.
;; The shared lazy-cons primitive for `concat` and `mapcat`.
(def -concat2
  (fn* [x y]
    (lazy-seq
      (let [s (seq x)]
        (if s
          (cons (first s) (-concat2 (rest s) y))
          (seq y))))))

;; `(concat & colls)` — lazy left-to-right catenation (JVM-idiom).
;; Folds the (finite) arg list with `-concat2`; element realization
;; stays lazy. `(concat)` → nil; `(concat a)` → `(seq a)`.
(def concat
  (fn* [& colls]
    ;; `(concat)` (no colls) → () not nil (D-164); the reduce init nil is
    ;; lifted to the empty list when nothing is catenated.
    (or (reduce -concat2 nil colls) '())))

;; `(-concat-seqs ss)` — lazily catenate a seq OF seqs, one level deep,
;; WITHOUT realizing the outer `ss` (the lazy counterpart of
;; `(apply concat ss)`, which would hang on an infinite outer because cw
;; v1's `apply` eagerly spreads its final argument). Walks `ss` under
;; `lazy-seq` so it composes with an infinite outer.
(def -concat-seqs
  (fn* [ss]
    (lazy-seq
      (let [s (seq ss)]
        (if s
          (-concat2 (first s) (-concat-seqs (rest s)))
          nil)))))

;; `(mapcat f & colls)` — the JVM shape `(apply concat (apply map f colls))`,
;; but with `-concat-seqs` instead of `apply concat` to stay lazy over an
;; infinite outer. Variadic over collections (`map` walks them in parallel;
;; D-070 multi-arity makes this reachable). `(apply map f colls)` only
;; spreads the finite `colls` list, so it never eager-realizes an infinite
;; coll; lazy throughout — `(take 5 (mapcat (fn [x] [x x]) (range)))` works.
;; `(mapcat f)` (no colls) returns the transducer `(comp (map f) cat)`
;; (D-177 single-arity); with colls it is the lazy variadic above.
(def mapcat
  (fn* [f & colls]
    (if (seq colls)
      (-concat-seqs (apply map f colls))
      (comp (map f) cat))))

;; `(tree-seq branch? children root)` — a lazy depth-first (pre-order) seq
;; of all nodes. `branch?` says whether a node can have children; `children`
;; returns them. Recurses through `tree-seq` itself (a top-level recursive
;; def) so it avoids a named local fn (D-147); `mapcat` keeps it lazy (D-134).
(def tree-seq
  (fn* [branch? children root]
    (lazy-seq
      (cons root
        (when (branch? root)
          (mapcat (fn* [c] (tree-seq branch? children c)) (children root)))))))

;; ----------------------------------------------------------------
;; Phase 14 §9.16 row 14.13 — D-134 cluster 1. High-frequency eager
;; collection helpers (Pattern A over reduce/conj/assoc/get/into/apply).
;; ----------------------------------------------------------------

;; `(update m k f & args)` — apply `f` (with trailing `args`) to the
;; value at key `k`. The shallow sibling of `update-in`.
(def update
  (fn* [m k f & args]
    (assoc m k (apply f (into [(get m k)] args)))))

;; `(vec coll)` — eager coerce any collection to a vector.
;; PERF: build via a transient (O(n) persistent! over a flat buffer) vs N persistent conjs O(n log n) [refs: O-003, D-180]
(def vec
  (fn* [coll] (persistent! (reduce conj! (transient []) coll))))
;; `(vector & args)` — construct a vector from its args (D-134). Unblocks
;; the common `(map vector ks vs)` / `(apply vector …)` idioms.
(def vector
  (fn* [& args] (vec args)))

;; `(mapv f coll)` — eager `map` returning a vector. Single-coll form.
(def mapv
  (fn* ([f coll] (reduce (fn* [acc x] (conj acc (f x))) [] coll))
       ([f c1 c2] (vec (map f c1 c2)))
       ([f c1 c2 c3] (vec (map f c1 c2 c3)))))

;; `(filterv pred coll)` — eager `filter` returning a vector.
(def filterv
  (fn* [pred coll]
    (reduce (fn* [acc x] (if (pred x) (conj acc x) acc)) [] coll)))

;; `(shuffle coll)` — a random permutation of coll as a vector. Fisher-Yates
;; over an immutable vector: for i from n-1 down to 1, swap index i with a
;; random index in [0, i] via two assocs. Placed after `vec` (D-134).
(def shuffle
  (fn* [coll]
    (let [v0 (vec coll)]
      (loop [v v0 i (dec (count v0))]
        (if (< i 1)
          v
          (let [j (rand-int (inc i))]
            (recur (assoc (assoc v i (nth v j)) j (nth v i)) (dec i))))))))

;; `(reverse coll)` — reverse order. conj onto an empty list prepends,
;; so reducing left-to-right yields the reversed sequence (a list).
;; `'()` (quoted) — a bare `()` is rejected as an empty-call expression.
(def reverse
  (fn* [coll] (reduce conj '() coll)))

;; `(last coll)` — the final element, or nil for an empty collection.
(def last
  (fn* [coll] (reduce (fn* [_ x] x) nil coll)))

;; ----------------------------------------------------------------
;; D-134 cluster 2 — eager map/seq helpers (Pattern A).
;; ----------------------------------------------------------------

;; `(reduce-kv f init m)` — reduce over a map's entries, calling
;; `(f acc k v)` for each key. Walks `(keys m)`.
(def reduce-kv
  (fn* [f init m]
    (reduce (fn* [acc k] (f acc k (get m k))) init (keys m))))

;; `(update-keys m f)` — new map with `(f k)` for each key, same vals.
(def update-keys
  (fn* [m f]
    (reduce (fn* [acc k] (assoc acc (f k) (get m k))) {} (keys m))))

;; `(update-vals m f)` — new map with `(f v)` for each val, same keys.
(def update-vals
  (fn* [m f]
    (reduce (fn* [acc k] (assoc acc k (f (get m k)))) {} (keys m))))

;; `(not-any? pred coll)` — true when `pred` is falsey for every item.
(def not-any?
  (fn* [pred coll] (not (some pred coll))))

;; `(not-every? pred coll)` — true when `pred` is falsey for at least one item.
(def not-every?
  (fn* [pred coll] (not (every? pred coll))))

;; D-134 cluster 3 — unblocked by D-136 (universal `=`).

;; `(dedupe coll)` — drop consecutive duplicates (eager vector).
;; `(dedupe)` — the transducer (stateful: remembers the previous input via
;; two volatiles, avoiding a sentinel value that data could collide with).
(def dedupe
  (fn* ([]
        (fn* [rf]
          (let [pv (volatile! nil) seen (volatile! false)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input]
                  (let [had @seen prior @pv]
                    (vreset! seen true)
                    (vreset! pv input)
                    (if (if had (= prior input) false) result (rf result input))))))))
       ([coll]
        ;; O(n) via the transducer (the old `(last acc)` per step was O(n²)
        ;; — `(dedupe (range 5000))` timed out). Returns a SEQ (JVM parity).
        (-seq-or-empty (into [] (dedupe) coll)))))

;; `(distinct coll)` — drop all duplicates, first occurrence wins.
;; Linear `=` scan (structural, so strings/collections dedupe); O(n^2).
(def distinct
  (fn* ([]
        ;; transducer: a volatile set of already-seen inputs
        (fn* [rf]
          (let [seen (volatile! #{})]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input]
                  (if (contains? @seen input)
                    result
                    (do (vswap! seen conj input) (rf result input))))))))
       ([coll]
        ;; O(n) via the transducer's volatile seen-set (the old linear
        ;; `some` scan per element was O(n²) — `(distinct (range 5000))`
        ;; timed out). Returns a SEQ (JVM parity).
        (-seq-or-empty (into [] (distinct) coll)))))

;; `(frequencies coll)` — map of item -> occurrence count. Keys via map
;; assoc (bit-pattern keyEq → number/keyword keys; structural keys D-092).
(def frequencies
  (fn* [coll]
    (reduce (fn* [acc x] (assoc acc x (inc (get acc x 0)))) {} coll)))

;; `(group-by f coll)` — map of (f x) -> vector of items. Same key caveat.
(def group-by
  (fn* [f coll]
    (reduce (fn* [acc x] (let [k (f x)] (assoc acc k (conj (get acc k []) x))))
            {}
            coll)))

;; ----------------------------------------------------------------
;; D-134 cluster 4 — eager seq helpers (Pattern A; recursion for
;; zipmap/interleave).
;; ----------------------------------------------------------------

;; `(empty? coll)` — true when coll has no items (nil counts as empty).
(def empty?
  (fn* [coll] (= 0 (count coll))))

;; `(fnil f x)` — f with its first arg defaulted to x when nil.
;; 1-arg patched form (multi-arg fnil awaits multi-arity follow-up).
;; `(fnil f x)` / `(fnil f x y)` / `(fnil f x y z)` — wrap f so its first
;; 1/2/3 args are replaced by the defaults when nil; trailing args pass
;; through (the returned fn is variadic, matching Clojure).
(def fnil
  (fn* ([f x] (fn* [a & args] (apply f (if (nil? a) x a) args)))
       ([f x y] (fn* [a b & args] (apply f (if (nil? a) x a) (if (nil? b) y b) args)))
       ([f x y z] (fn* [a b c & args] (apply f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c) args)))))

;; `(interpose sep)` / `(interpose sep coll)` — sep between consecutive items.
;; The 1-arg form is a stateful transducer (emit sep before every item except
;; the first); the 2-arg form is eager (prepend sep before each, drop the
;; leading sep with `rest`).
(def interpose
  (fn* ([sep]
        (fn* [rf]
          (let [started (volatile! false)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input]
                  (if @started
                    (let [sepr (rf result sep)]
                      (if (reduced? sepr) sepr (rf sepr input)))
                    (do (vreset! started true) (rf result input))))))))
       ([sep coll]
        (rest (reduce (fn* [acc x] (conj (conj acc sep) x)) [] coll)))))

;; `(zipmap ks vs)` — map pairing keys with values, stopping at the
;; shorter. Recursive parallel walk.
;; loop/recur (NOT fn* self-recursion): the original `(assoc (zipmap …) …)`
;; was non-tail and segfaulted at ~5000 pairs. Looping head-first also makes
;; duplicate keys last-wins (Clojure semantics; the old recurse-first was
;; head-wins).
(def zipmap
  (fn* [ks vs]
    (loop [ks (seq ks) vs (seq vs) acc {}]
      (if (and ks vs)
        (recur (next ks) (next vs) (assoc acc (first ks) (first vs)))
        acc))))

;; `(interleave & colls)` — alternate items from N colls, stopping when the
;; shortest is exhausted. LAZY (JVM parity, F-011): `(take 4 (interleave (range)
;; (repeat :x)))`→`(0 :x 1 :x)` — two infinite colls now work (the prior eager
;; loop returned empty). `(seq colls)` guards 0-arity from vacuous infinite
;; recursion. Self-recursive → two-step `(def … nil)` so the body resolves it.
(def interleave nil)
(def interleave
  (fn* [& colls]
    (lazy-seq
      (let* [ss (map seq colls)]
        (if (and (seq colls) (every? identity ss))
          (concat (map first ss) (apply interleave (map rest ss)))
          nil)))))

;; ----------------------------------------------------------------
;; D-134 cluster 5 — reduce-shaped helpers (Pattern A).
;; sort / sort-by deferred (need a compare op + sort algorithm).
;; ----------------------------------------------------------------

;; `(max-key f & xs)` — the x with the greatest (f x); ties keep the
;; earlier-seen. `(min-key …)` is the mirror. reduce uses (first xs)
;; as the seed (≥1 arg required, matching JVM).
(def max-key
  (fn* [f & xs]
    (reduce (fn* [a b] (if (>= (f a) (f b)) a b)) xs)))

(def min-key
  (fn* [f & xs]
    (reduce (fn* [a b] (if (<= (f a) (f b)) a b)) xs)))

;; `(flatten coll)` — the contents of any nested sequential as a single
;; flat SEQUENCE (matches JVM: a lazy seq, not a vector). Non-sequential
;; leaves are kept; an empty/non-sequential input yields an empty seq.
;; (cljw collapses the empty seq to nil — the empty-seq≡nil divergence,
;; D-164 — so `(flatten [])` is nil rather than `()`.)
(def flatten
  (fn* [coll]
    (filter (fn* [x] (not (sequential? x)))
            (rest (tree-seq sequential? seq coll)))))

;; `(reductions f init coll)` — like reduce but collects every
;; intermediate, starting with init (eager vector). 3-arg form;
;; the 2-arg `(reductions f coll)` awaits multi-arity.
;; Returns a SEQ (JVM parity). (last acc) per step is O(n²) — a perf
;; residual tracked alongside D-163, not the seq-vs-vector concern here.
(def reductions
  (fn*
    ([f coll]
      (let [s (seq coll)]
        (if s
          (reductions f (first s) (rest s))
          (seq (vector (f))))))
    ([f init coll]
      (seq (reduce (fn* [acc x] (conj acc (f (last acc) x))) [init] coll)))))

;; ----------------------------------------------------------------
;; D-134 cluster 6 — trivial accessors (no compare dependency).
;; sort / sort-by await D-137 (compare is numeric-only).
;; ----------------------------------------------------------------

;; `(second coll)` — the second item (nil if absent).
(def second (fn* [coll] (first (rest coll))))

;; `(ffirst coll)` — `(first (first coll))`.
(def ffirst (fn* [coll] (first (first coll))))

;; `(key e)` / `(val e)` — the key / value of a map entry. cw v1 represents
;; map entries as 2-element vectors (`(first {:a 1})` → `[:a 1]`), so these
;; index positionally rather than calling a JVM Map.Entry accessor.
(def key (fn* [e] (nth e 0)))
(def val (fn* [e] (nth e 1)))

;; `(not-empty coll)` — coll if it has items, else nil.
(def not-empty (fn* [coll] (if (empty? coll) nil coll)))

;; `(take-last n coll)` — the last n items (eager).
(def take-last
  (fn* [n coll] (reverse (take n (reverse coll)))))

;; `(drop-last coll)` / `(drop-last n coll)` — all but the last 1 / n items.
;; clj's n-arity `(map (fn [x _] x) s (drop n s))` pairs each element with the
;; one n ahead, so the map stops when `drop` runs out — dropping the last n.
(def drop-last
  (fn* ([s] (drop-last 1 s))
       ([n s] (map (fn* [x _] x) s (drop n s)))))

;; ----------------------------------------------------------------
;; D-134 sort cluster — unblocked by D-137 (general compare).
;; STABLE merge sort (ADR-0053 D3: Clojure sort is stable). Eager
;; vector result (DIVERGENCE: JVM returns a seq). cmp returns -1/0/1.
;; ----------------------------------------------------------------

;; Stable merge of two cmp-sorted vectors; on a tie the left item wins
;; (`<=` keeps `a` first), preserving input order.
;; loop/recur (NOT fn* self-recursion): the merge is non-tail when written
;; as `(into [x] (-merge-sorted …))`, so it recursed one frame per element
;; and `(sort (range 5000))` segfaulted. Accumulating into `acc` and
;; recurring is constant-stack; stability holds (`<= 0` drains `a` first).
(def -merge-sorted
  (fn* [cmp a b]
    (loop [a a b b acc []]
      (if (empty? a)
        (into acc b)
        (if (empty? b)
          (into acc a)
          (if (<= (cmp (first a) (first b)) 0)
            (recur (rest a) b (conj acc (first a)))
            (recur a (rest b) (conj acc (first b)))))))))

;; Merge sort over a vector with comparator `cmp`.
(def -msort
  (fn* [cmp v]
    (if (<= (count v) 1)
      v
      (let [mid (quot (count v) 2)]
        (-merge-sorted cmp
                       (-msort cmp (vec (take mid v)))
                       (-msort cmp (vec (drop mid v))))))))

;; Normalize a user comparator (Clojure AFunction.compare semantics, D-159):
;; a Boolean result reads as a less-than predicate (true → -1; else `(cmp b a)`
;; true → 1; else 0); a number passes through (its sign is the order). Lets
;; `(sort < coll)` / `(sort > coll)` work next to numeric comparators, since
;; `-merge-sorted` compares the result with `<= 0`.
(def -comparator
  (fn* [cmp]
    (fn* [a b]
      (let [r (cmp a b)]
        (if (boolean? r)
          (if r -1 (if (cmp b a) 1 0))
          r)))))

;; `(sort coll)` — natural order via `compare`. `(sort comp coll)` — order by
;; the (boolean-or-number) comparator `comp`. Stable (merge sort). Returns a
;; SEQ (JVM parity, clj-verified), not a vector; `-msort` sorts a vector
;; internally and `seq` exposes it as a sequence (empty → nil per D-164).
(def sort
  (fn* ([coll] (-seq-or-empty (-msort compare (vec coll))))
       ([comp coll] (-seq-or-empty (-msort (-comparator comp) (vec coll))))))

;; `(sort-by f coll)` — order by `(compare (f a) (f b))`. `(sort-by f comp coll)`
;; — order by `(comp (f a) (f b))`. Stable. Returns a SEQ (see `sort`).
(def sort-by
  (fn* ([f coll]
        (-seq-or-empty (-msort (fn* [a b] (compare (f a) (f b))) (vec coll))))
       ([f comp coll]
        (let [c (-comparator comp)]
          (-seq-or-empty (-msort (fn* [a b] (c (f a) (f b))) (vec coll)))))))

;; ----------------------------------------------------------------
;; D-134 range + index fns. All finite arities are lazy seqs (D-168):
;; the 1/2-arg arms delegate to the 3-arg lazy-seq form, so `(range n)`
;; matches JVM (`seq?` true, `(take 5 (range 1e9))` returns without
;; realizing the whole range). The F-004 chunked LongRange is the
;; eventual finished form for cheap count/reduce; this lazy-seq
;; unification is the interim shared shape (F-011 — one mechanism, no
;; per-arity divergence).
;; ----------------------------------------------------------------

;; `(iterate f x)` — infinite lazy seq: x, (f x), (f (f x)), …. Defined
;; before `range` because `(range)`'s 0-arg body calls it: cw v1 resolves
;; a fn body's free symbols at analysis time, so a forward ref to a Var
;; def'd later in the file fails to resolve.
(def iterate
  (fn* [f x] (lazy-seq (cons x (iterate f (f x))))))

;; `(range)` → infinite lazy 0,1,2,…; `(range n)` → 0..n-1;
;; `(range start end)` → start..end-1; `(range start end step)` → stepped.
;; The 1/2-arg arms reduce to the 3-arg lazy-seq body (inline lazy
;; recursion, NOT take-while — that is def'd later in the file, and a fn
;; body's free symbols resolve at analysis time). Continuation matches
;; JVM: step>0 while x<end, step<0 while x>end, step=0 while x≠end (so
;; `(range 0 10 0)` is infinite 0s, `(range 5 5 0)` is empty).
(def range
  (fn* ([] (iterate inc 0))
       ([n] (range 0 n 1))
       ([start end] (range start end 1))
       ([start end step]
        ;; Finite fixed-precision integer ranges become a compact `.range`
        ;; value (ADR-0063 / O-001: O(1) count/nth, tight reduce, chunked
        ;; seq). Float / bigint / step-0 (infinite) ranges stay the lazy
        ;; cons body below — `-range` only mints for the integer case.
        (if (and (int? start) (int? end) (int? step) (not (= step 0)))
          (-range start end step)
          (lazy-seq
            (if (if (> step 0)
                  (< start end)
                  (if (< step 0) (> start end) (not (= start end))))
              (cons start (range (+ start step) end step))
              nil))))))

;; ----------------------------------------------------------------
;; D-134 index/accessor cluster. `iterate` is defined above `range` (its
;; 0-arg body resolves it at analysis time); map-indexed / keep-indexed
;; are eager index walks; butlast drops the final element.
;; ----------------------------------------------------------------

;; `(map-indexed f coll)` — eager map passing (index, item) to f.
(def map-indexed
  (fn* ([f]
        ;; transducer arity: stateful index starting at 0
        (fn* [rf]
          (let [iv (volatile! -1)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input] (rf result (f (vswap! iv inc) input)))))))
       ([f coll]
        ;; Returns a SEQ (JVM parity).
        (-seq-or-empty (mapv (fn* [i] (f i (nth coll i))) (range (count coll)))))))

;; `(keep-indexed f)` / `(keep-indexed f coll)` — like map-indexed but drops
;; nil results. The 1-arg form is a stateful transducer (running index); the
;; 2-arg form returns a SEQ (JVM parity).
(def keep-indexed
  (fn* ([f]
        (fn* [rf]
          (let [iv (volatile! -1)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input]
                  (let [i (vswap! iv inc) v (f i input)]
                    (if (nil? v) result (rf result v))))))))
       ([f coll]
        (-seq-or-empty (reduce (fn* [acc i]
                                 (let [r (f i (nth coll i))] (if (nil? r) acc (conj acc r))))
                               []
                               (range (count coll)))))))

;; `(butlast coll)` — all but the final element, or nil for a coll of
;; ≤1 element (JVM returns `(seq ret)` → nil when empty). The `(seq …)`
;; wrap is required now that `(rest …)` of a 1-elem coll is `()` not nil
;; (D-164): without it `(butlast [1])` would be `()` instead of nil.
(def butlast
  (fn* [coll] (seq (reverse (rest (reverse coll))))))

;; ----------------------------------------------------------------
;; ADR-0054 cycle 4 — the last lazy-cluster cycle. repeat / repeatedly /
;; cycle / take-while / drop-while / partition are lazy `.clj`, mirroring
;; the cycle-2/3 lazy-cons shape so they compose with infinite producers
;; (`(take 3 (take-while #(< % 100) (range)))`, `(first (cycle [5 6]))`).
;; ----------------------------------------------------------------

;; `(repeat x)` → infinite lazy x,x,x,…; `(repeat n x)` → n copies (lazy).
(def repeat
  (fn* ([x] (lazy-seq (cons x (repeat x))))
       ([n x] (lazy-seq (if (> n 0) (cons x (repeat (dec n) x)) nil)))))

;; `(any? x)` → always true (clojure 1.9; the "matches anything" spec pred).
(def any? (fn* [x] true))

;; `(nfirst x)` → `(next (first x))`.
(def nfirst (fn* [x] (next (first x))))

;; `(prn-str & xs)` / `(println-str & xs)` → the `prn`/`println` output as a
;; string (readable / human form + trailing newline), no stdout.
(def prn-str (fn* [& xs] (str (apply pr-str xs) "\n")))
(def println-str (fn* [& xs] (str (apply print-str xs) "\n")))

;; `(printf fmt & args)` → print the `format`-ed string (no trailing newline).
(def printf (fn* [fmt & args] (print (apply format fmt args))))

;; `(replicate n x)` → a seq of x repeated n times (deprecated alias for
;; `(repeat n x)`, kept for compatibility — clj defines it as `(take n (repeat x))`).
(def replicate
  (fn* [n x] (take n (repeat x))))

;; `(repeatedly f)` → infinite lazy (f),(f),…; `(repeatedly n f)` → n calls.
(def repeatedly
  (fn* ([f] (lazy-seq (cons (f) (repeatedly f))))
       ([n f] (take n (repeatedly f)))))

;; `(cycle coll)` → infinite repetition of coll's items; empty → empty.
;; Lazy-catenates one pass of `coll` ahead of the next cycle layer; the
;; trailing `(cycle coll)` is a thunk, so no eager infinite recursion.
(def cycle
  (fn* [coll]
    (lazy-seq
      (let [s (seq coll)]
        (if s
          (-concat2 s (cycle coll))
          nil)))))

;; `(take-while pred coll)` — leading run for which pred is truthy (lazy).
;; `(take-while pred)` / `(take-while pred coll)` — the leading pred-truthy run.
;; The 1-arg form is a transducer that `reduced`s the result on the first
;; falsey item; the 2-arg form is lazy.
(def take-while
  (fn* ([pred]
        (fn* [rf]
          (fn* ([] (rf))
               ([result] (rf result))
               ([result input]
                (if (pred input) (rf result input) (reduced result))))))
       ([pred coll]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (if (pred (first s))
                (cons (first s) (take-while pred (rest s)))
                nil)
              nil))))))

;; `(drop-while pred)` / `(drop-while pred coll)` — drop the leading pred-truthy
;; run. The 1-arg form is a stateful transducer (drop until the first falsey,
;; then pass everything); the 2-arg form is the lazy tail.
(def drop-while
  (fn* ([pred]
        (fn* [rf]
          (let [dv (volatile! true)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input]
                  (let [drop? @dv]
                    (if (and drop? (pred input))
                      result
                      (do (vreset! dv false) (rf result input)))))))))
       ([pred coll]
        (lazy-seq
          (let [s (seq coll)]
            (if (and s (pred (first s)))
              (drop-while pred (rest s))
              s))))))
;; `(split-with pred coll)` → `[(take-while …) (drop-while …)]`.
(def split-with
  (fn* [pred coll] [(take-while pred coll) (drop-while pred coll)]))
;; `(split-at n coll)` — `[(take n coll) (drop n coll)]`. The pair holds lazy
;; seqs (JVM-faithful); printing the pair directly shows `#<lazy_seq>` per the
;; nested-lazy printer limit (D-134 note / ADR-0054 cycle-2), but the values
;; and destructured/realized use are correct.
(def split-at
  (fn* [n coll] [(take n coll) (drop n coll)]))

;; `(counted? x)` — true iff x supports O(1) count (vector / map / set /
;; list in cw v1). Lazy seqs and strings are NOT counted. `(reversible? x)`
;; — true iff x supports rseq: vector + sorted map/set (LLRB, ADR-0057).
(def counted? (fn* [x] (or (vector? x) (map? x) (set? x) (list? x))))
(def reversible? (fn* [x] (or (vector? x) (sorted? x))))
;; Numeric / collection / ident predicates (clj-source-faithful). `rational?`
;; = exact non-float; `seqable?` = nil / coll / string / seq; `indexed?` =
;; O(1) nth (vector in cw v1); the ident family keys on keyword/symbol +
;; `namespace` for the qualified/simple split.
(def rational? (fn* [x] (or (integer? x) (ratio? x) (decimal? x))))
(def seqable? (fn* [x] (or (nil? x) (seq? x) (coll? x) (string? x))))
(def indexed? (fn* [x] (vector? x)))
(def ident? (fn* [x] (or (keyword? x) (symbol? x))))
(def simple-ident? (fn* [x] (and (ident? x) (not (namespace x)))))
(def qualified-ident? (fn* [x] (boolean (and (ident? x) (namespace x) true))))
(def simple-symbol? (fn* [x] (and (symbol? x) (not (namespace x)))))
(def qualified-symbol? (fn* [x] (boolean (and (symbol? x) (namespace x) true))))
(def simple-keyword? (fn* [x] (and (keyword? x) (not (namespace x)))))
(def qualified-keyword? (fn* [x] (boolean (and (keyword? x) (namespace x) true))))
;; `(take-nth n)` / `(take-nth n coll)` — every nth item. The 1-arg form is a
;; stateful transducer (emit when the running index is a multiple of n); the
;; 2-arg form is lazy.
(def take-nth
  (fn* ([n]
        (fn* [rf]
          (let [iv (volatile! -1)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input]
                  (let [i (vswap! iv inc)]
                    (if (zero? (rem i n)) (rf result input) result)))))))
       ([n coll]
        (lazy-seq
          (let [s (seq coll)]
            (if s (cons (first s) (take-nth n (drop n s))) nil))))))
;; `(list* a* tail)` — prepend the leading args onto the final seq arg.
;; Explicit 1-4 arg forms (the common cases incl. the `(list* a args)`
;; macro idiom); 5+-arg variadic deferred (needs a primitive-only spread).
(def list*
  (fn* ([args] (seq args))
       ([a args] (cons a args))
       ([a b args] (cons a (cons b args)))
       ([a b c args] (cons a (cons b (cons c args))))))
;; `(partition-by f coll)` — lazy seq of runs where `(f x)` is constant
;; (a new run starts each time `(f x)` changes) (D-134). `run` is a
;; `take-while` lazy_seq (NOT `(cons fst (take-while …))`): a raw cons
;; onto a lazy_seq caches a wrong `count` (D-153), but a lazy_seq counts
;; by realizing — and `(f (first s)) = fv` so the first element is in run.
(def partition-by
  (fn* ([f]
        ;; Stateful transducer: accumulate a run in `a`; on an `f`-value change
        ;; flush the run downstream, then (unless reduced) start a new run with
        ;; the boundary element. The completion arm flushes the final run.
        (fn* [rf]
          (let [a (volatile! [])
                pv (volatile! nil)
                started (volatile! false)]
            (fn* ([] (rf))
                 ([result]
                  (let [result (if (zero? (count @a))
                                 result
                                 (let [v @a] (vreset! a []) (unreduced (rf result v))))]
                    (rf result)))
                 ([result input]
                  (let [val (f input) prev @pv was @started]
                    (vreset! pv val)
                    (vreset! started true)
                    (if (or (not was) (= val prev))
                      (do (vswap! a conj input) result)
                      (let [v @a]
                        (vreset! a [])
                        (let [ret (rf result v)]
                          (if (reduced? ret) ret (do (vswap! a conj input) ret)))))))))))
       ([f coll]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (let [fv (f (first s))
                    run (take-while (fn* [x] (= (f x) fv)) s)]
                (cons run (partition-by f (drop (count run) s))))
              nil))))))

;; `(partition n coll)` / `(partition n step coll)` — lazy seq of n-item
;; groups stepping by `step` (default n); the final incomplete group is
;; dropped (matches JVM). Each group is an eager `take` list.
(def partition
  (fn* ([n coll] (partition n n coll))
       ([n step coll]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (let [p (take n s)]
                (if (= (count p) n)
                  (cons p (partition n step (drop step s)))
                  nil))
              nil))))
       ;; 4-arg pad (D-134): the final short partition is padded with
       ;; `pad` up to length n (JVM `(take n (concat p pad))` — if pad is
       ;; too short the last partition stays < n).
       ([n step pad coll]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (let [p (take n s)]
                (if (= (count p) n)
                  (cons p (partition n step pad (drop step s)))
                  (list (take n (concat p pad)))))
              nil))))))

;; `(partition-all n [step] coll)` — like `partition` but KEEPS the final
;; short partition (no length check, no pad). Lazy (D-134).
(def partition-all
  (fn* ([n]
        ;; transducer: buffer inputs in a volatile vector, emit each full
        ;; partition; the 1-arg completion flushes the short final one.
        (fn* [rf]
          (let [a (volatile! [])]
            (fn* ([] (rf))
                 ([result]
                  (let [result (if (empty? @a)
                                 result
                                 (let [v @a] (vreset! a []) (unreduced (rf result v))))]
                    (rf result)))
                 ([result input]
                  (vswap! a conj input)
                  (if (= n (count @a))
                    (let [v @a] (vreset! a []) (rf result v))
                    result))))))
       ([n coll] (partition-all n n coll))
       ([n step coll]
        (lazy-seq
          (let [s (seq coll)]
            (when s
              (cons (take n s) (partition-all n step (drop step s)))))))))

;; `(splitv-at n coll)` — `[(vec (take n coll)) (vec (drop n coll))]`
;; (the vector-returning sibling of split-with; D-134).
(def splitv-at
  (fn* [n coll] [(vec (take n coll)) (vec (drop n coll))]))

;; ----------------------------------------------------------------
;; Phase 7 §9.9 row 7.7 — hybrid polymorphic primitives' protocol surface.
;;
;; The `count` / `seq` / `conj` / `reduce` primitives keep their
;; Zig Tag-switch fast-path for native tags and route the slow-path
;; (= extend-type targets) through these protocol declarations. The
;; fqcn the slow-path matches in `MethodEntry.protocol_name` is the
;; bare symbol name (no ns prefix, per `allocFqcn` at
;; `lang/primitive/protocol.zig:41-51`), so `"IPersistentCollection"`
;; is the string the dispatch path uses.
;;
;; Methods land one per cycle: cycle 1 adds `-count`; cycles 2-4 add
;; `-seq` / `-cons` / `-reduce` as `seq` / `conj` / `reduce` are
;; wired into their hybrid shape.
;; ----------------------------------------------------------------

(defprotocol IPersistentCollection (-count [c]) (-cons [c x]) (-empty [c]))
(defprotocol Seqable (-seq [c]))
(defprotocol IReduce (-reduce [c f]))
(defprotocol ISeq (-first [s]) (-rest [s]) (-next [s]))
(defprotocol ILookup (-lookup [c k]))
(defprotocol Indexed (-nth [c i]))
(defprotocol Associative (-assoc [c k v]) (-contains-key? [c k]))
(defprotocol IPersistentMap (-without [m k]) (-keys [m]) (-vals [m]))
(defprotocol IPersistentSet (-disjoin [s k]))
;; `Sequential` is a zero-method MARKER protocol (JVM `clojure.lang.Sequential`):
;; a type that declares it prints as its seq and answers `sequential?` true
;; (D-190 / ADR-0068). The native seq tags carry sequential-ness by tag; this
;; marker is for `deftype`s like `Eduction`.
(defprotocol Sequential)

;; `(eduction xform* coll)` — a reducible + seqable view that applies the
;; composed transducer on demand (D-160 residual, ADR-0067). A `deftype`
;; rather than an alias for `sequence`: that makes eduction RE-ITERABLE
;; (each `reduce` re-runs the whole pipeline via `-reduce`→`transduce`, so a
;; side-effecting xform fires every time — the JVM contract) and DISTINCT
;; from `sequence` (a cached lazy-seq). `-reduce` is declared `[c f]` on
;; IReduce but implemented variadic to also serve `reduce`'s 3-arg
;; `(-reduce c f init)` call (which `into` uses). `(completing f)` supplies
;; the 0/1-arity the transducer protocol needs for an arbitrary `f` (e.g.
;; `conj`, which has no 1-arg completion). The seqable half delegates to the
;; `sequence` lazy bridge. (`first`/`rest` directly on an Eduction need the
;; Seqable→seq coercion that cljw's first/rest lack — D-189; `(seq e)` works.)
(deftype Eduction [xform coll]
  Sequential
  IReduce
  (-reduce [this f & more]
    (if (seq more)
      (transduce (.xform this) (completing f) (first more) (.coll this))
      (transduce (.xform this) (completing f) (.coll this))))
  Seqable
  (-seq [this] (seq (sequence (.xform this) (.coll this)))))

(def eduction
  (fn* [& args]
    (->Eduction (apply comp (butlast args)) (last args))))

;; `(satisfies? protocol x)` — true iff x's type implements protocol.
;; Thin wrapper over the rt/__satisfies? primitive, which consults x's
;; TypeDescriptor (typed_instance / reified_instance / native-Tag
;; default registry) for a method entry naming the protocol.
(def satisfies?
  (fn* [protocol x] (rt/__satisfies? protocol x)))

;; `(extends? protocol atype)` — true iff atype (a type, e.g. a defrecord/
;; deftype name or (rt/__native-type :tag)) carries the protocol. The
;; type-level counterpart of satisfies?: satisfies? takes a value, extends?
;; takes the type directly.
(def extends?
  (fn* [protocol atype] (rt/__extends? protocol atype)))

;; `(class x)` — the type of x as an interned type value (ADR-0059):
;; native types render as Long / String / PersistentVector, user records
;; as their name; (class nil) → nil. Interned, so (= (class 5) (class 6))
;; is true and a class is a valid map key (group-by class).
(def class (fn* [x] (rt/__class x)))

;; `(class? x)` — true iff x is a class object (what (class …) returns).
(def class? (fn* [x] (rt/__class? x)))

;; `(type x)` — (:type (meta x)) when present, else (class x).
(def type (fn* [x] (or (:type (meta x)) (class x))))

;; `(resolve sym)` — the Var sym names in the current namespace (or the
;; named ns when qualified), or nil. Returns a var_ref that derefs to the
;; Var's value and prints #'ns/name.
(def resolve (fn* [sym] (rt/__resolve sym)))

;; Multimethod introspection — thin fn wrappers over the rt/ primitives
;; (defmulti / defmethod / prefer-method are macros in macro_transforms).
;; `methods` → dispatch-val→method map; `get-method` → the method (or nil);
;; `remove-method` → the multifn; `prefers` → the prefer table.
(def methods (fn* [multifn] (rt/__methods multifn)))
(def get-method (fn* [multifn dispatch-val] (rt/__get-method multifn dispatch-val)))
(def remove-method (fn* [multifn dispatch-val] (rt/__remove-method! multifn dispatch-val)))
(def prefers (fn* [multifn] (rt/__prefers multifn)))

;; `(memoize f)` returns a cached version of f: each distinct argument
;; tuple computes f once, then returns the stored result. Keys the
;; atom-backed cache by `(vec args)` — vectors compare by value (D-092),
;; and the captured `cache` atom is shared by reference across calls so
;; swap! mutations persist despite snapshot closure capture. Defined at
;; the end of core.clj so `vec` / `contains?` / `get` / `assoc` (earlier
;; defns) are all resolvable (core.clj is analysed top-to-bottom).
(def memoize
  (fn* [f]
    (let* [cache (atom {})]
      (fn* [& args]
        (let* [k (vec args)]
          (if (contains? (deref cache) k)
            (get (deref cache) k)
            (let* [v (apply f args)]
              (do (swap! cache assoc k v) v))))))))

;; `(vary-meta obj f & args)` → obj with metadata `(apply f (meta obj) args)`.
(def vary-meta
  (fn* [obj f & args]
    (with-meta obj (apply f (meta obj) args))))

;; `(alter-meta! iref f & args)` — atomically set a mutable ref's metadata to
;; `(apply f current-meta args)`, returning the new metadata. `reset-meta!` is
;; the primitive that mutates the ref's meta slot (var / atom).
(def alter-meta!
  (fn* [iref f & args]
    (reset-meta! iref (apply f (meta iref) args))))

;; `(re-seq re s)` — seq of successive non-overlapping match strings of `re`
;; in `s` via the `re-find-from` primitive (loop/recur, advancing past each
;; match's end; +1 on an empty match to avoid looping). Capture-group vectors
;; land when groups do (regex cycle 3+).
(def re-seq
  (fn* [re s]
    (loop [pos 0 acc []]
      (let [m (re-find-from re s pos)]
        (if (nil? m)
          (seq acc)
          (recur (if (= (nth m 2) (nth m 1)) (inc (nth m 2)) (nth m 2))
                 (conj acc (nth m 0))))))))

;; ----------------------------------------------------------------
;; Ad-hoc hierarchies — make-hierarchy / derive / underive / isa? /
;; parents / ancestors / descendants over a global hierarchy.
;; DIVERGENCE: cljw has no JVM Class, so clojure.core's class? branches
;; are dropped (keyword / symbol / vector tags only). The global
;; hierarchy is an atom (cljw has no alter-var-root). derive is lenient
;; on namespacing (clojure.core asserts namespaced tags). Map entries are
;; [k v] vectors → nth for key/val.
;; ----------------------------------------------------------------

(def make-hierarchy
  (fn* [] {:parents {} :descendants {} :ancestors {}}))

(def -global-hierarchy (atom (make-hierarchy)))

;; Propagate a target relationship across source and source's sources.
(def -derive-tf
  (fn* [m source sources target targets]
    (reduce (fn* [ret k]
              (assoc ret k (reduce conj (get targets k #{}) (cons target (get targets target)))))
            m (cons source (get sources source)))))

(def derive
  (fn* ([tag parent] (swap! -global-hierarchy derive tag parent) nil)
       ([h tag parent]
        (let [tp (:parents h) td (:descendants h) ta (:ancestors h)]
          (if (contains? (get tp tag) parent)
            h
            (if (contains? (get ta tag) parent)
              (throw (ex-info (str tag " already has " parent " as ancestor") {}))
              (if (contains? (get ta parent) tag)
                (throw (ex-info (str "Cyclic derivation: " parent " has " tag " as ancestor") {}))
                {:parents (assoc tp tag (conj (get tp tag #{}) parent))
                 :ancestors (-derive-tf ta tag td parent ta)
                 :descendants (-derive-tf td parent ta tag td)})))))))

(def isa?
  (fn* ([child parent] (isa? (deref -global-hierarchy) child parent))
       ([h child parent]
        (or (= child parent)
            ;; class-hierarchy arm (clj's Class.isAssignableFrom): when both
            ;; are class values, `child` isa `parent` if it is a subclass.
            (and (class? child) (class? parent) (-class-isa? child parent))
            (contains? (get (:ancestors h) child) parent)
            (and (vector? parent) (vector? child)
                 (= (count parent) (count child))
                 (loop [ret true i 0]
                   (if (or (not ret) (= i (count parent)))
                     ret
                     (recur (isa? h (nth child i) (nth parent i)) (inc i)))))))))

(def parents
  (fn* ([tag] (parents (deref -global-hierarchy) tag))
       ([h tag] (not-empty (get (:parents h) tag)))))

(def ancestors
  (fn* ([tag] (ancestors (deref -global-hierarchy) tag))
       ([h tag] (not-empty (get (:ancestors h) tag)))))

(def descendants
  (fn* ([tag] (descendants (deref -global-hierarchy) tag))
       ([h tag] (not-empty (get (:descendants h) tag)))))

(def underive
  (fn* ([tag parent] (swap! -global-hierarchy underive tag parent) nil)
       ([h tag parent]
        (let [pm (:parents h)
              cps (if (get pm tag) (disj (get pm tag) parent) #{})
              new-parents (if (not-empty cps) (assoc pm tag cps) (dissoc pm tag))
              deriv-seq (flatten (map (fn* [e] (cons (nth e 0) (interpose (nth e 0) (nth e 1))))
                                      (seq new-parents)))]
          (if (contains? (get pm tag) parent)
            (reduce (fn* [hh pr] (derive hh (nth pr 0) (nth pr 1)))
                    (make-hierarchy) (partition 2 deriv-seq))
            h)))))

;; `(doc sym)` — print a Var's documentation (name / arglists / docstring)
;; in clojure.repl/doc's format (D-187 part 2). The Var-metadata surface
;; (D-183) makes this the user-facing payoff: `(defn f "d" [x] x)` then
;; `(doc f)` shows the docstring. cljw has no `clojure.repl` ns yet, so this
;; lives in core (always referred); the `clojure.repl` home is a later
;; structural refinement. `print-doc` formats off `(meta var-ref)`; the
;; qualified name comes from `(str var-ref)` (`#'ns/name`) minus the `#'`.
(def print-doc
  (fn* [v]
    (let [m (meta v)]
      (println "-------------------------")
      (println (subs (str v) 2))
      (when (:arglists m) (println (:arglists m)))
      (when (:doc m) (println (str "  " (:doc m)))))))

(defmacro doc [sym]
  (list (quote print-doc) (list (quote var) sym)))

;; `(pvalues & exprs)` — clj's parallel-eval of each expr. cw v1 is single-
;; threaded so it expands to `pcalls` over thunks = SEQUENTIAL eval (result
;; identical to clj; parallelism deferred to Phase-15 threading, D-224).
(defmacro pvalues [& exprs]
  ;; `apply list` realizes the map seq so the expansion is a concrete list,
  ;; not a cons over a lazy tail (which the macroexpander cannot re-analyze).
  (apply list (quote pcalls)
         (map (fn* [e] (list (quote fn*) [] e)) exprs)))

;; `(with-redefs [v override …] body…)` — temporarily set each Var v's ROOT to
;; override for body's dynamic extent, restoring originals in a `finally` (clj's
;; test util; cw is single-threaded so this is a root swap via `alter-var-root`,
;; not a thread-local binding frame — D-225). Now writable with syntax-quote.
(defn with-redefs-fn [binding-map func]
  (let [vars (keys binding-map)
        orig (zipmap vars (map deref vars))]
    (doseq [v vars] (alter-var-root v (constantly (binding-map v))))
    (try
      (func)
      (finally
        (doseq [v vars] (alter-var-root v (constantly (orig v))))))))
(defmacro with-redefs [bindings & body]
  `(with-redefs-fn
     (hash-map ~@(interleave (map (fn* [k] (list (quote var) k)) (take-nth 2 bindings))
                             (take-nth 2 (rest bindings))))
     (fn* [] ~@body)))

(defmacro with-open
  "bindings => [name init ...]. Evaluates body in a try expression with
  names bound to the values of the inits, and a finally clause that calls
  (.close name) on each name in reverse order."
  [bindings & body]
  (cond
    (= (count bindings) 0) `(do ~@body)
    (symbol? (bindings 0)) `(let ~(subvec bindings 0 2)
                              (try
                                (with-open ~(subvec bindings 2) ~@body)
                                (finally
                                  (. ~(bindings 0) ~'close))))
    :else (throw (ex-info "with-open only allows Symbols in bindings" {}))))


;; `(requiring-resolve sym)` → resolve a qualified symbol, requiring its
;; namespace first if needed. Throws on a non-qualified symbol (clj parity).
;; Defined late: depends on qualified-symbol? / namespace / require / resolve.
(def requiring-resolve
  (fn* [sym]
    (if (qualified-symbol? sym)
      (do (require (symbol (namespace sym))) (resolve sym))
      (throw (ex-info (str "Not a qualified symbol: " sym) {:sym sym})))))
