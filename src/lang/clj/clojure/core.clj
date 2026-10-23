;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.core API (originally Rich Hickey; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

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

;; `*unchecked-math*` — a JVM compiler flag selecting wrapping (unchecked)
;; integer ops. cljw's numeric tower auto-promotes (F-005), so this is a no-op
;; flag like *warn-on-reflection*; defined so code that toggles it loads
;; (clojure.data.avl and other libs set! it at the top of a file).
(def ^:dynamic *unchecked-math* false)

;; `*assert*` — clj's compile-time assert-elision flag. Default true (asserts
;; check), matching clj. cljw's `assert` is a Zig macro that always emits the
;; check, so toggling this to false does NOT elide a cljw `(assert …)` (a no-op
;; like the flags above); but user/lib macros that READ `*assert*` — e.g.
;; clojure.core.memoize's `(when *assert* …)` arg-validation — resolve it correctly.
(def ^:dynamic *assert* true)

;; `*command-line-args*` — the seq of strings passed after the run-mode main
;; option (`cljw -M -m my.ns a b` → `("a" "b")`; nil when none). The `-M`/`-X`
;; run modes set its root via alter-var-root before the app forms eval (D-310,
;; ADR-0111); a plain `cljw <file>` / `-e` leaves it nil.
(def ^:dynamic *command-line-args* nil)

;; REPL history vars — upstream core.clj shape (unbound roots; a REPL binds
;; them per evaluation). The nREPL session engine (ADR-0170) binds + rolls
;; them per session; the CLI REPL adopts them via the same engine later.
(def ^:dynamic
 ^{:doc "bound in a repl thread to the most recent value printed"
   :added "1.0"}
 *1)

(def ^:dynamic
 ^{:doc "bound in a repl thread to the second most recent value printed"
   :added "1.0"}
 *2)

(def ^:dynamic
 ^{:doc "bound in a repl thread to the third most recent value printed"
   :added "1.0"}
 *3)

(def ^:dynamic
 ^{:doc "bound in a repl thread to the most recent exception caught by the repl"
   :added "1.0"}
 *e)

;; `*out*` / `*err*` — first-class cljw writer VALUES (ADR-0138). The roots are
;; a stdout / stderr text_io Writer (UTF-8, no JVM Charset/PrintWriter); print/
;; println/pr/prn/newline (core.zig emitToStdout) render + push to the bound
;; `*out*`, and `(.write *out* s)` / `.append` / `.flush` dispatch on the value's
;; own method_table — no sentinel, no special-case. `with-out-str` / nREPL
;; capture are plain `(binding [*out* (cljw.internal/__string-writer)] …)` rebinds.
(def ^:dynamic *out* (cljw.internal/__stdout-writer))
(def ^:dynamic *err* (cljw.internal/__stderr-writer))
;; `*in*` — the bindable input reader var (D-414). ROOT is a process-stdin
;; reader (demand-filled, blocking — clj `System.in` parity), so `(read-line)`
;; works on piped/redirected/interactive stdin; `with-in-str` /
;; `(binding [*in* rdr] …)` rebind it to a string reader.
(def ^:dynamic *in* (cljw.internal/__stdin-reader))
;; `*print-length*` / `*print-level*` (ADR-0088) are interned in Zig
;; (`bootstrap.registerPrintLimitVars`) alongside the other cached-pointer
;; dynamic vars (*ns*, *data-readers*) so the renderer reads them via a cached
;; `*const Var`; not defined here.

;; `*clojure-version*` / `(clojure-version)` — the Clojure language version cljw
;; targets (the 1.12 surface; the clj oracle is 1.12.x per F-011). Real libs gate
;; features on (:minor *clojure-version*) and print (clojure-version).
(def *clojure-version* {:major 1 :minor 12 :incremental 0 :qualifier nil})

(def clojure-version
  (fn* []
    (let* [v   *clojure-version*
           inc (:incremental v)
           q   (:qualifier v)]
      (str (:major v) "." (:minor v)
           (if inc (str "." inc) "")
           (if q (str "-" q) "")))))

;; `(list & items)` constructs a PersistentList in argument order. `apply`
;; may bind any ISeq as the rest argument, so copy through an empty list
;; instead of returning that sequence or inheriting its metadata. Two passes
;; use only Stage-0 primitives; reverse/reduce are defined later in bootstrap.
(def list
  (fn* [& xs]
    (let* [reversed (loop* [s (seq xs) acc '()]
                      (if s
                        (recur (next s) (conj acc (first s)))
                        acc))]
      (loop* [s (seq reversed) acc '()]
        (if s
          (recur (next s) (conj acc (first s)))
          acc)))))

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
;; `(first (drop 100 (range)))` → 100). `take` is lazy too: constructing
;; `(take n source)` does not pull source before the result is demanded.
;; The `-*-eager` map/filter/keep/remove/drop leaves are deleted.
;; `map` — 1/2/3-coll + n-coll variadic. Multi-coll walks colls in parallel,
;; stopping at the shortest (D-134). The n-ary arm delegates to `-map-n-step`,
;; forward-declared here so map can reference it at def time (fn-body symbols
;; resolve at def time; `declare` interns the Var first — D-446).
;; PERF: O-023 fusion descriptor `[xform coll]` for the reduce-site fuse. If
;; `coll` already carries one (a chained map/filter), compose the transducers
;; (`comp` runs left-to-right per element: inner xform first) + reach past to the
;; base source — so a whole `(filter p (map g …))` chain collapses to ONE
;; `[composed-xform base-coll]` that `reduce` runs as a single `transduce` pass.
;; `comp`/`nth` resolve at call time (map/filter run post-load), so the forward
;; reference is safe. [refs: O-023, D-386]
(def -fuse-descriptor
  (fn* [this-xform coll]
    [this-xform coll]))

;; PERF: O-023 internal lazy body for `map` — recurses on ITSELF (no fuse stamp)
;; so the per-node lazy path (first/rest/take) pays nothing; only the public
;; `map` stamps the descriptor on the outer node reduce sees. [refs: O-023]
(def -map-lazy
  (fn* [f coll]
    ;; PERF: chunked source → transform a whole 32-chunk per thunk (O-004).
    (lazy-seq
      (let [s (seq coll)]
        (if s
          (if (chunked-seq? s)
            ;; PERF: O-032 in-Zig chunk drain — the per-element `.clj` loop moved
            ;; into `cljw.internal/__chunk-map-step` (producer analogue of reduceFn's O-004 drain).
            (chunk-cons (cljw.internal/__chunk-map-step f s) (-map-lazy f (chunk-rest s)))
            (cons (f (first s)) (-map-lazy f (rest s))))
          nil)))))
;; PERF: O-062 internal lazy body for 2/3-coll `map`: one lazy node per element
;; (clj's multi-coll map is unchunked), whose body is the Zig `__map-step`
;; (seq all, f on the firsts, recur on the rests). Passes itself as `self`.
(def ^:private -map-n-lazy
  (fn* ([f c1 c2] (lazy-seq (cljw.internal/__map-step f -map-n-lazy c1 c2)))
       ([f c1 c2 c3] (lazy-seq (cljw.internal/__map-step f -map-n-lazy c1 c2 c3)))))
;; Forward-declared so map's n-ary arm resolves it at def time (D-446).
(declare -map-n-step)
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
        ;; PERF: O-023 stamp the fusion descriptor on the outer node so `reduce`
        ;; fuses; the lazy body (`-map-lazy`) is unchanged → seq ops identical.
        (-lazy-set-fuse (-map-lazy f coll) (-fuse-descriptor (map f) coll)))
       ;; PERF: O-062 the 2/3-coll step body runs in Zig (`__map-step`): same
       ;; unchunked one-f-per-node shape as clj, the lazy node stays here.
       ([f c1 c2] (-map-n-lazy f c1 c2))
       ([f c1 c2 c3] (-map-n-lazy f c1 c2 c3))
       ;; n-ary: zip 4+ colls, stopping at the shortest (clj parity).
       ([f c1 c2 c3 & colls]
        (map (fn* [args] (apply f args)) (-map-n-step (conj colls c3 c2 c1))))))
;; n-ary `map` step: lazily zip the seqs in `cs`, yielding a seq of each
;; position's firsts until any seq is exhausted. Top-level recursive because a
;; named local fn is unavailable in this bootstrap layer (D-147, cf. tree-seq).
(def -map-n-step
  (fn* [cs]
    (lazy-seq
      (let* [ss (map seq cs)]
        (if (every? identity ss)
          (cons (map first ss) (-map-n-step (map rest ss)))
          nil)))))
;; PERF: O-023 internal lazy body for `filter` — recurses on itself, no stamp.
(def -filter-lazy
  (fn* [pred coll]
    (lazy-seq
      (let [s (seq coll)]
        (if s
          (if (chunked-seq? s)
            ;; PERF: O-032 in-Zig chunk drain — the per-element `.clj` loop moved
            ;; into `cljw.internal/__chunk-filter-step` (survivors-only partial chunk).
            (chunk-cons (cljw.internal/__chunk-filter-step pred s) (-filter-lazy pred (chunk-rest s)))
            (let [v (first s)]
              (if (pred v)
                (cons v (-filter-lazy pred (rest s)))
                (-filter-lazy pred (rest s)))))
          nil)))))
(def filter
  (fn* ([pred]
        ;; transducer arity
        (fn* [rf]
          (fn* ([] (rf))
               ([result] (rf result))
               ([result input] (if (pred input) (rf result input) result)))))
       ([pred coll]
        ;; PERF: O-023 stamp the fusion descriptor; lazy body is `-filter-lazy`.
        (-lazy-set-fuse (-filter-lazy pred coll) (-fuse-descriptor (filter pred) coll)))))
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
       ([n coll]
        (lazy-seq
          (if (pos? n)
            (let [s (seq coll)]
              (if s
                (cons (first s) (take (dec n) (rest s)))
                nil))
            nil)))))
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
(def nthnext
  (fn* [coll n]
    (loop [s (seq coll) n n]
      (if (and s (> n 0))
        (recur (next s) (dec n))
        s))))
;; n <= 0 returns coll UNCHANGED (clj preserves the input, not a seq view):
;; `(nthrest [1 2 3] 0)` => [1 2 3], not (1 2 3).
(def nthrest (fn* [coll n] (if (pos? n) (drop n coll) coll)))
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
                (let [size (cljw.internal/__chunk-count s)
                      b (chunk-buffer size)]
                  (loop [i 0]
                    (when (< i size)
                      (let [r (f (cljw.internal/__chunk-nth s i))]
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
;; The JVM-exact gate (D-369): `instance?` on IEditableCollection is true
;; for hash-based vectors/maps/sets AND for a user deftype that declares
;; the interface (whose asTransient the transient primitive dispatches,
;; e.g. flatland.ordered), and false for nil / lists / sorted colls /
;; records — the earlier native-tag approximation (set?/map?/vector?
;; minus sorted/record) mis-sent interface-recognised deftype sets down
;; the transient path with no dispatch behind it.
;; (cljw.internal/__instance-of? directly: `instance?` itself defs later in this file.)
(def -editable?
  (fn* [coll]
    (cljw.internal/__instance-of? clojure.lang.IEditableCollection coll)))

;; `(into to from)` conj every item of `from` onto `to`; `(into to xform
;; from)` does so through the transducer `xform`. Defined here (Layer 2)
;; over reduce/transduce — supersedes the eager into primitive (which
;; had no other Zig callers). `conj`'s 1-arg completion arity makes the
;; bare-`conj` reducing fn work for the transduce path.
;; PERF: editable targets build via a transient (O(n) persistent! over a flat buffer) vs N persistent conjs O(n log n) [refs: O-003, D-180]
(def into
  (fn* ([] [])
       ([to] to)
       ([to from]
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

;; `(swap-vals! a f & args)` / `(reset-vals! a v)` return the atomic `[old new]`
;; pair. A CAS-retry over the now-atomic `compare-and-set!` so the returned `old`
;; is exactly the value the successful swap replaced — capturing `@a` separately
;; would, under concurrency, pair a stale `old` with a `new` from a different
;; swap. `f` may run more than once (the swap! contract).
(def swap-vals!
  (fn* [a f & args]
    (loop []
      (let [old @a
            new (apply f old args)]
        (if (compare-and-set! a old new)
          [old new]
          (recur))))))
(def reset-vals!
  (fn* [a v]
    (loop []
      (let [old @a]
        (if (compare-and-set! a old v)
          [old v]
          (recur))))))

;; `pmap` / `pcalls` are PARALLEL (D-224) and defined later in this file
;; (search "parallel map"), once `future`/`lazy-seq`/`if-let`/named-`fn` are
;; available — they need those, so they cannot live this early in the bootstrap.

;; `(dorun coll)` / `(dorun n coll)` — realize a (lazy) seq for side effects,
;; holding no head; returns nil. `(doall coll)` / `(doall n coll)` — same forcing
;; but returns the (now-realized) head. `if` (not `when`/`and`) keeps these
;; bootstrap-order-safe. The lazy-seq realization utilities (clojure.core).
(def dorun
  (fn* ([coll]
        ;; PERF: the seq/next walk runs natively, a chunk at a time over a
        ;; chunked seq. [refs: O-077]
        (cljw.internal/__dorun coll))
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

;; PERF: O-023 reduce-site fusion engine — the Zig `reduce` (3-arg) delegates here
;; when its source carries a `[xform coll]` fuse descriptor (stamped by map/filter).
;; Walk the descriptor chain composing the transducers inner-first (`(comp inner
;; outer)`) and reaching the base source, then run ONE `transduce` pass — so
;; `(reduce f init (filter p (map g xs)))` collapses to a single zero-intermediate
;; sweep over `xs`. `completing` keeps the 1-arg arity a no-op (reduce has no
;; completion step). Defined after `comp`/`transduce`/`completing`; called only at
;; runtime, so no load-order hazard. [refs: O-023, D-386]
(def -fused-reduce
  (fn* [f init coll]
    (loop [xform nil c coll]
      (let [fd (-lazy-get-fuse c)]
        (if fd
          (recur (if xform (comp (nth fd 0) xform) (nth fd 0)) (nth fd 1))
          (transduce xform (completing f) init c))))))

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
;; clj some-fn is min-1-arity (D-446): `(some-fn)` throws. `[p & preds]`
;; enforces ≥1; rebind preds to the full list so the body is unchanged.
;; clj applies EACH predicate to EACH arg (arg-outer, pred-inner), not all
;; args to each predicate: `((some-fn p1 p2) x y)` is `(or (p1 x) (p2 x)
;; (p1 y) (p2 y))`. It returns the first truthy value (some-fn's actual
;; value, not a boolean), else the last one evaluated (nil when no args).
(def some-fn
  (fn* [p & preds]
    (let* [preds (cons p preds)]
      (fn* [& args]
        (loop [as args last-v nil]
          (if (seq as)
            (let* [x (first as)
                   v (loop [ps preds seen nil]
                       (if (seq ps)
                         (let* [r ((first ps) x)]
                           (if r r (recur (rest ps) r)))
                         seen))]
              (if v v (recur (rest as) v)))
            last-v))))))

;; The `every-pred` mirror: `(and (p1 x) (p2 x) (p1 y) (p2 y))`, short-circuit
;; to a boolean false on the first falsey, true when all pass (or no args).
;; clj every-pred is min-1-arity (D-446): `(every-pred)` throws.
(def every-pred
  (fn* [p & preds]
    (let* [preds (cons p preds)]
      (fn* [& args]
        (loop [as args]
          (if (seq as)
            (let* [x (first as)
                   ok (loop [ps preds]
                        (if (seq ps)
                          (if ((first ps) x) (recur (rest ps)) false)
                          true))]
              (if ok (recur (rest as)) false))
            true))))))

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
;; PERF: O-027 a 2-arg fast arity avoids the variadic rest-pack + `apply` on the
;; hot 2-arg path (`(not= 0 (mod x p))` in sieve's filter pred, per element ×
;; per filter-level). The variadic clause starts at 3 args (Clojure requires the
;; variadic's required-param count to exceed every fixed arity). Arities match
;; clj exactly: `([x])`→false, `([x y])`, `([x y & more])` — NO 0-arg clause, so
;; `(not=)` throws an arity error like clj (it does NOT return false). [refs: O-027, D-386]
(def not= (fn* ([a] false)
                ([a b] (not (= a b)))
                ([a b c & more] (not (apply = a b c more)))))
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
(def bit-and-not (fn* ([x y] (bit-and x (bit-not y)))
                      ([x y & more] (reduce bit-and-not (bit-and-not x y) more))))

;; `(peek coll)` / `(pop coll)` — stack ops. Vector: peek = last element,
;; pop = drop the last (returns a vector). List/seq: peek = first, pop =
;; rest. peek of empty is nil; pop of empty throws (JVM parity). D-134.
;; peek/pop are stack ops — defined ONLY on nil / list / vector (clj's
;; IPersistentStack). A non-stack seqable (string, lazy seq, range) throws in
;; clj (ClassCastException), so cljw must NOT silently fall through to first/
;; rest there (D-218). nil → nil for both (clj parity).
;; A PersistentQueue is also IPersistentStack: peek = front (oldest), pop =
;; drop the front (ADR-0087); pop of empty returns the empty queue (no throw).
;; D-280d2: defined HERE (not in the protocol block below) so peek/pop can
;; reference it without a forward ref; peek/pop use the cljw.internal/__satisfies? primitive
;; (always available) rather than the satisfies? wrapper (defined later).
(defprotocol IPersistentStack (-peek [c]) (-pop [c]))
(def peek
  (fn* [coll]
    (if (nil? coll)
      nil
      (if (queue? coll)
        (first coll)
        (if (vector? coll)
          (if (pos? (count coll)) (nth coll (dec (count coll))) nil)
          (if (list? coll)
            (first coll)
            ;; D-280d2: a deftype/reify implementing clojure.lang.IPersistentStack.
            (if (cljw.internal/__satisfies? IPersistentStack coll)
              (-peek coll)
              (throw (ClassCastException. "Can't peek: not a stack (list, vector)")))))))))
(def pop
  (fn* [coll]
    (if (nil? coll)
      nil
      (if (queue? coll)
        (cljw.internal/__queue-pop coll)
        (if (vector? coll)
          (if (pos? (count coll))
            (cljw.internal/__vector-pop coll)
            (throw (IllegalStateException. "Can't pop empty vector")))
          (if (list? coll)
            (if (seq coll)
              (rest coll)
              (throw (IllegalStateException. "Can't pop empty list")))
            ;; D-280d2: a deftype/reify implementing clojure.lang.IPersistentStack.
            (if (cljw.internal/__satisfies? IPersistentStack coll)
              (-pop coll)
              (throw (ClassCastException. "Can't pop: not a stack (list, vector)")))))))))

;; `(find m k)` — the map entry for key k if present, else nil (distinguishes
;; "absent" from "present with nil value" via contains?). The result is a real
;; map ENTRY, as in clj: `(map-entry? (find {:a 1} :a))` is true and `key`/`val`
;; work on it. It built a plain 2-vector until entries became a distinct type,
;; which made `(key (find m k))` throw — and `find` also backs `.entryAt`, so
;; every Associative host-method path inherited the bug. The entry's key is
;; the one STORED in m (clj Associative.entryAt), not the probe:
;; `(find {1N :a} 1)` is [1N :a], `(find {0.0 :z} -0.0)` is [0.0 :z].
(def find
  (fn* [m k] (cljw.internal/__entry-at m k)))

;; `(subvec v start [end])` — the elements of v in [start, end) (end
;; defaults to (count v)) as a vector. For a vector this is JVM's O(1)
;; shared-structure VIEW (the `.sub_vector` tag; D-583); a non-vector
;; seqable falls back to the eager take/drop build.
(def ^:private -subvec-slow
  (fn* ([v start end]
        (when (nil? v)
          (throw (NullPointerException. "subvec: nil vector")))
        (when-not (vector? v)
          (throw (ClassCastException. "subvec: expected a vector")))
        ;; clj bounds-checks (0 <= start <= end <= count) and throws
        ;; IndexOutOfBounds — it does NOT clamp like take/drop would
        ;; (`(subvec [1 2 3] 1 10)` throws, not `[2 3]`).
        ;;
        ;; clj's `RT.subvec` takes primitive `int` params, so a float / ratio
        ;; index is coerced via `Number.intValue` (truncate toward zero; NaN → 0)
        ;; BEFORE the bounds check: (subvec [0 1 2] 2.72 3.14) → [2],
        ;; (subvec [0 1 2] 1/2 4/3) → [0], (subvec [0 1 2] ##NaN 3) → [0 1 2],
        ;; (subvec [0 1 2] 1 ##NaN) → start 1 > end 0 → out-of-bounds. Coercing
        ;; here is also what keeps a non-integer index off `__subvec`'s raw i64
        ;; cast, which would `@panic` on a NaN / ratio (ADR-0019 — no panic on
        ;; user input). A non-number index (`:a`, `nil`, a symbol) has no
        ;; `intValue`, so `int` throws — matching clj's cast-failure throw.
        (let [->idx (fn* [x] (if (and (float? x) (not (== x x))) 0 (int x)))
              start (->idx start)
              end (->idx end)
              c (count v)]
          ;; clj throws IndexOutOfBoundsException here (NOT an ex-info) — so a
          ;; `(catch IndexOutOfBoundsException …)` around a subvec works.
          (when (or (< start 0) (< end start) (< c end))
            (throw (IndexOutOfBoundsException.
                     (str "subvec index out of bounds: start=" start ", end=" end ", count=" c))))
          ;; O(1) shared-structure view, preserving numeric coercion and bounds.
          (cljw.internal/__subvec v start end)))))

(def subvec
  (fn* ([v start] (subvec v start (count v)))
       ([v start end]
        ;; PERF: in-bounds integer indices over a vector are answered by one
        ;; native step; nil means "not that shape", so everything below is the
        ;; coercing / throwing path. [refs: O-073]
        (or (cljw.internal/__subvec-fast v start end)
            (-subvec-slow v start end)))))

;; `(bounded-count n coll)` — for a `counted?` coll return its FULL count (clj:
;; `(bounded-count 3 (range 100))` → 100, range is O(1) counted); otherwise walk
;; at most n elements so it terminates on infinite / expensive seqs (D-134).
(def bounded-count
  (fn* [n coll]
    (if (counted? coll)
      (count coll)
      (loop [c 0 s (seq coll)]
        (if (if s (< c n) false) (recur (inc c) (next s)) c)))))

;; `(rand-nth coll)` — a uniformly random element of coll (which must be
;; indexed / counted). Empty coll → an out-of-bounds error (JVM parity).
(def rand-nth
  (fn* [coll] (nth coll (rand-int (count coll)))))

;; `(random-sample prob)` / `(random-sample prob coll)` — keep each element of
;; coll independently with probability prob (Bernoulli per element). 1-arity is
;; a stateless transducer. JVM parity: clojure.core/random-sample.
(def random-sample
  (fn* ([prob] (filter (fn* [_] (< (rand) prob))))
       ([prob coll] (filter (fn* [_] (< (rand) prob)) coll))))

;; ----------------------------------------------------------------
;; Phase 6.16.b-3 helpers — used by clojure.set Group C (project /
;; rename / index / join). Pattern A composition; no Zig leaves.
;; ----------------------------------------------------------------

;; `(select-keys m ks)` — return a map containing only the keys in
;; `ks` that are present in `m`. As in clj it conjoins the `find` ENTRY,
;; so a present nil value survives and the result carries m's STORED key
;; (`(select-keys {1N :a} [1])` is {1N :a}). `m` must be associative or nil: JVM `RT/find` casts a
;; non-Associative, non-nil arg to `Map` → ClassCastException, so a
;; string / list / number throws rather than silently returning `{}`.
(def select-keys
  (fn* [m ks]
    ;; No lookup is attempted when no keys were requested.
    (if-let [ks (seq ks)]
      (if (or (nil? m) (associative? m))
        (reduce (fn* [acc k]
                  (if-let [e (find m k)]
                    (assoc acc (nth e 0) (nth e 1))
                    acc))
                {}
                ks)
        (throw (ClassCastException. "select-keys: not associative")))
      {})))

;; `(merge & maps)` — right-most key wins. nil args are skipped.
;; JVM `merge` reduces with `conj`, so a later arg that is a 2-vector
;; or a map entry is added AS an entry (`(merge {:a 1} [:b 2])` →
;; `{:a 1 :b 2}`), not iterated as a map — the old `keys`/`assoc` body
;; rejected a plain vector. Variadic via `[& maps]`; 0-arity returns nil
;; (matches JVM). `(if (nil? acc) {} acc)` seeds a map only when the
;; first arg was nil, so a vector-first `merge` keeps vector-conj.
(def merge
  (fn* [& maps]
    (if (= 0 (count maps))
      nil
      (reduce (fn* [acc m]
                (if (nil? m)
                  acc
                  (conj (if (nil? acc) {} acc) m)))
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
;; clj distinct? is min-1-arity (D-446): `(distinct?)` throws.
(def distinct?
  (fn* [x & args]
    (let* [args (cons x args)]
      (= (count args) (count (set args))))))

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
;; PERF: O-025 indexed descent for the 3-arg fast path — `(nth ks i)` per level
;; instead of `(next ks)`, which on a vector path (the common shape) allocates a
;; subvec/seq view EACH level. The path is passed unchanged + walked by index, so
;; `(update-in m [:a :b :c] inc)` ×10000 (nested_update) pays no per-level next-ks
;; alloc. [refs: O-025, D-386]
(def -update-in-idx
  (fn* [m ks f i n]
    (let [k (nth ks i)
          ni (inc i)]
      (if (< ni n)
        (assoc m k (-update-in-idx (get m k) ks f ni n))
        (assoc m k (f (get m k)))))))
;; PERF: a 3-arg fast arity avoids the variadic rest-pack + `apply` + `into`
;; (O-020) and descends by index (O-025). The variadic arity keeps the `& args`
;; form. [refs: O-020, O-025, D-386].
(def update-in
  (fn*
    ;; PERF: O-033 route a non-empty VECTOR path through the in-Zig `-update-in`
    ;; (descent+ascent in one prim, no `.clj` per-level recursion); `-update-in-idx`
    ;; stays the fallback for non-vector / empty paths (clj-parity edge unchanged).
    ([m ks f] (if (and (vector? ks) (seq ks))
                (cljw.internal/__update-in m ks f)
                (-update-in-idx m ks f 0 (count ks))))
    ([m ks f & args]
     (let [k (first ks) nks (next ks)]
       (if nks
         (assoc m k (apply update-in (get m k) nks f args))
         (assoc m k (apply f (get m k) args)))))))

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

;; Lazily flatten the outer sequence one level at a time.
(def -concat-seqs
  (fn* [ss]
    (lazy-seq
      (let [s (seq ss)]
        (if s
          (-concat2 (first s) (-concat-seqs (rest s)))
          nil)))))

;; The two-argument path keeps its recursive tail directly in -concat2's
;; second position; variadic calls flatten their remaining collections lazily.
(def concat
  (fn* ([] (lazy-seq nil))
       ([x] (-concat2 nil x))
       ([x y] (-concat2 x y))
       ([x y & zs] (-concat-seqs (cons x (cons y zs))))))

;; apply inspects concat's bounded argument prefix and preserves its lazy rest.
(def mapcat
  (fn* [f & colls]
    (if (seq colls)
      (apply concat (apply map f colls))
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

;; `(file-seq dir)` — lazy depth-first seq of `dir` and everything under it,
;; as host File values. The JVM definition is exactly this `tree-seq` over
;; `.isDirectory` / `.listFiles`, so it is expressed the same way here rather
;; than as a separate walker. A non-directory yields just itself.
(def ^{:doc "A tree seq on host files: dir and everything beneath it, depth-first.
  A non-directory yields just itself."
       :arglists '([dir])}
  file-seq
  (fn* [dir]
    (tree-seq (fn* [f] (.isDirectory f))
              (fn* [d] (seq (.listFiles d)))
              dir)))

;; `(line-seq rdr)` — lazy seq of the lines of `rdr` (a host reader exposing
;; `.readLine`, e.g. from `clojure.java.io/reader`). The head line is read
;; eagerly (matching JVM `line-seq`'s when-let); the tail is lazy. nil at EOF.
(def line-seq
  (fn* [rdr]
    (let* [line (.readLine rdr)]
      (if (nil? line)
        nil
        (cons line (lazy-seq (line-seq rdr)))))))

;; `(read-line)` — read the next line from `*in*` (a host reader), or nil at
;; EOF. The root is a process-stdin reader (blocking, clj parity); a nil-bound
;; `*in*` still yields nil rather than raising.
(def read-line
  (fn* [] (when (some? *in*) (.readLine *in*))))

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
  ;; PERF: single-coll form builds through a transient, clj's own shape (O(n) persistent! over a flat buffer vs N persistent conjs) [refs: O-003, D-180]
  (fn* ([f coll] (persistent! (reduce (fn* [v o] (conj! v (f o))) (transient []) coll)))
       ([f c1 c2] (vec (map f c1 c2)))
       ([f c1 c2 c3] (vec (map f c1 c2 c3)))
       ([f c1 c2 c3 & colls] (vec (apply map f c1 c2 c3 colls)))))

;; `(await & agents)` — block until all actions dispatched to each agent SO FAR
;; have run. `__agent-await` enqueues a barrier action to every agent (so they
;; drain concurrently) and returns a promise the drainer delivers AFTER that
;; barrier's `notifyWatches` (incl. the barrier's own no-op `[s s]` fire,
;; clj-faithful) — then we block on each promise. This delivers-after-notify
;; ordering replaces the earlier in-body `(deliver p s)` sentinel, which raced:
;; the awaiter could wake before the barrier's watch fired (D-368, ADR-0093 am1).
;; clj uses a per-agent CountDownLatch; the promise is cljw's cross-thread latch,
;; held alive by the barrier sitting in the agent's queue. (await-for + the
;; in-transaction / in-action illegality check are a later slice.)
(def await
  (fn* [& agents]
    (let [ps (mapv (fn* [a] (cljw.internal/__agent-await a)) agents)]
      (dorun (map deref ps)))))

;; `(await-for timeout-ms & agents)` — like `await` but bounded: logical true
;; once every agent's barrier completes within timeout-ms (total, not per-agent),
;; false on timeout. clj uses one CountDownLatch + a single timeout; here a
;; per-promise deadline budget over the same barrier promises. `sentinel` is a
;; fresh atom so `identical?` tells a timeout apart from a delivered agent-state
;; value (the barrier delivers the agent's state, which can be any value).
(def await-for
  (fn* [timeout-ms & agents]
    (let [ps (mapv (fn* [a] (cljw.internal/__agent-await a)) agents)
          sentinel (atom nil)
          deadline (+ (System/currentTimeMillis) timeout-ms)]
      (every? (fn* [p]
                (let [remaining (- deadline (System/currentTimeMillis))]
                  (if (pos? remaining)
                    (not (identical? sentinel (deref p remaining sentinel)))
                    false)))
              ps))))

;; agent error mode — the :fail/:continue keyword over the internal flag.
;; :fail (the default with no error-handler) halts the agent on a thrown action
;; (agent-error returns it, sends throw, restart-agent recovers); :continue drops
;; the error and keeps draining. error-handler / set-error-handler! are kernel
;; primitives (the handler runs on the drainer in both modes; D-441).
(def set-error-mode!
  (fn* [a mode] (cljw.internal/__agent-set-fail-mode a (= mode :fail)) a))
(def error-mode
  (fn* [a] (if (cljw.internal/__agent-fail-mode? a) :fail :continue)))

;; `agent-errors` / `clear-agent-errors` — clj-DEPRECATED multi-error API,
;; superseded by `agent-error` (singular) which cljw has (ADR-0155 / D-442).
;; Defined as sugar over the live primitives: a cljw agent holds at most one
;; error, so agent-errors returns a one-element seq (or nil), and
;; clear-agent-errors is clj's exact `(restart-agent a @a)` (so on a NON-failed
;; agent it inherits restart-agent's behaviour — a separate pre-existing gap:
;; clj rejects "does not need a restart", cljw currently permits it).
(def agent-errors
  (fn* [a] (when-let [e (agent-error a)] (list e))))
(def clear-agent-errors
  (fn* [a] (restart-agent a (deref a)) nil))

;; `(io! & body)` — guard I/O against transaction retry. A `dosync` body may run
;; more than once, so I/O inside it would repeat; `io!` throws
;; IllegalStateException when a transaction is running on this thread, else runs
;; body. An optional leading string is the exception message (clj `io!`). Uses
;; `new` (not the `.`-suffix form) so the class symbol survives syntax-quote.
(defmacro io! [& body]
  (let [message (when (string? (first body)) (first body))
        body (if message (next body) body)]
    `(if (cljw.internal/__in-transaction?)
       (throw (new IllegalStateException ~(if message message "I/O in transaction")))
       (do ~@body))))

;; `(filterv pred coll)` — eager `filter` returning a vector.
(def filterv
  (fn* [pred coll]
    (reduce (fn* [acc x] (if (pred x) (conj acc x) acc)) [] coll)))

;; `(shuffle coll)` — a random permutation of coll as a vector. Fisher-Yates
;; over an immutable vector: for i from n-1 down to 1, swap index i with a
;; random index in [0, i] via two assocs. Placed after `vec` (D-134).
(def instance? (fn* [c x] (cljw.internal/__instance-of? c x)))

(def shuffle
  (fn* [coll]
    ;; JVM shuffle copies a java.util.Collection before shuffling.
    (when (nil? coll)
      (throw (NullPointerException. "shuffle: nil collection")))
    (when-not (instance? java.util.Collection coll)
      (throw (ClassCastException. "shuffle: expected a Collection")))
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

;; `(reduce-kv f init m)` — reduce over an associative, calling `(f acc k v)`
;; for each entry. A map uses its keys; a VECTOR (and map-entry, which is a
;; 2-vector) uses integer indices as keys (clj treats both as IKVReduce). Both
;; arms route through `reduce`, so a `(reduced …)` short-circuits.
;; The vector arm uses loop*/recur (not `range`/`map-indexed`, which are defined
;; later in this file — symbols resolve at analyze time) and honours `reduced`.
(def reduce-kv
  (fn* [f init m]
    (if (vector? m)
      (loop* [i 0 acc init]
        (if (< i (count m))
          (let* [r (f acc i (nth m i))]
            (if (reduced? r) (deref r) (recur (inc i) r)))
          acc))
      ;; IKVReduce first (a deftype declaring `kvreduce`, D-400 — clj
      ;; consults the interface before any fallback); the sentinel keyword
      ;; is interned, so `identical?` detects "no impl" exactly.
      (let* [r (cljw.internal/__kv-reduce-or m f init :clojure.core/kv-reduce-none)]
        (if (identical? r :clojure.core/kv-reduce-none)
          ;; Walk ENTRIES, never keys-then-get: a key that is not `=` to
          ;; itself (##NaN, or a list holding it) misses its own lookup, so
          ;; `(get m k)` would hand f nil instead of the stored value.
          (reduce (fn* [acc e] (f acc (nth e 0) (nth e 1))) init m)
          r)))))

;; `(update-keys m f)` — new map with `(f k)` for each key, same vals.
;; Entry walk, not keys-then-get, for the same NaN-key reason as reduce-kv.
(def update-keys
  (fn* [m f]
    (reduce (fn* [acc e] (assoc acc (f (nth e 0)) (nth e 1))) {} m)))

;; `(update-vals m f)` — new map with `(f v)` for each val, same keys.
;; Entry walk, not keys-then-get, for the same NaN-key reason as reduce-kv.
(def update-vals
  (fn* [m f]
    (reduce (fn* [acc e] (assoc acc (nth e 0) (f (nth e 1)))) {} m)))

;; `(seq-to-map-for-destructuring s)` — clojure 1.11. Builds a map from the rest
;; args of a `& {:keys […]}` call: kwargs pairs, a single trailing map, or a mix
;; (kwargs + trailing map merged). See
;; https://clojure.org/reference/special_forms#keyword-arguments
;; `second`/`nnext`/`map?` are defined later in this file — use early primitives.
(defn seq-to-map-for-destructuring [s]
  (if (next s)
    (loop [m {} s s]
      (if (seq s)
        (if (map? (first s))
          (recur (conj m (first s)) (next s))
          (recur (assoc m (first s) (first (next s))) (next (next s))))
        m))
    (if (seq s) (first s) {})))

;; `(iteration step & {:keys [somef vf kf initk]})` — clojure 1.11. Seed `step`
;; with `initk` (then `(kf ret)`), producing `(vf ret)` while `(somef ret)`; a
;; lazy seq. Built for consuming chunked / paginated sources (call until exhausted).
(def iteration
  (fn [step & {:keys [somef vf kf initk]
               :or {vf identity kf identity somef some? initk nil}}]
    (letfn [(it [k]
              (lazy-seq
                (let [ret (step k)]
                  (when (somef ret)
                    (cons (vf ret) (it (kf ret)))))))]
      (it initk))))

;; `(not-any? pred coll)` — true when `pred` is falsey for every item.
(def not-any?
  (fn* [pred coll] (not (some pred coll))))

;; `(not-every? pred coll)` — true when `pred` is falsey for at least one item.
(def not-every?
  (fn* [pred coll] (not (every? pred coll))))

;; D-134 cluster 3 — unblocked by D-136 (universal `=`).

;; Lazy `dedupe` engine. The inner fn* `recur`s on the consecutive-duplicate
;; skip so a long run of duplicates is consumed within ONE lazy-seq thunk
;; (stack-safe); the emit case re-enters -dedupe-step (the laziness boundary).
;; `have-prev` separates "no previous element yet" from a genuine nil element
;; (so a leading nil is not dropped). A self-named `(fn step …)` is avoided —
;; cljw fn* has no self-name (D-147).
(def -dedupe-step
  (fn* [coll prev have-prev]
    (lazy-seq
      ((fn* [xs prev have-prev]
         (let [s (seq xs)]
           (when s
             (let [f (first s)]
               (if (if have-prev (= prev f) false)
                 (recur (rest s) prev have-prev)
                 (cons f (-dedupe-step (rest s) f true)))))))
       coll prev have-prev))))

;; `(dedupe coll)` — drop consecutive duplicates, lazily (composes with an
;; infinite source: `(take 3 (dedupe (map f (range))))` terminates).
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
        ;; Lazy: prev-tracking -dedupe-step. O(n), one `=` per element.
        (-dedupe-step coll nil false))))

;; Lazy `distinct` engine. The inner fn* `recur`s on the already-seen skip so
;; a long run of duplicates is consumed within ONE lazy-seq thunk (stack-safe);
;; the emit case re-enters -distinct-step (the laziness boundary). A self-named
;; `(fn step …)` is avoided — cljw fn* has no self-name (D-147).
(def -distinct-step
  (fn* [coll seen]
    (lazy-seq
      ((fn* [xs seen]
         (let [s (seq xs)]
           (when s
             (let [f (first s)]
               (if (contains? seen f)
                 (recur (rest s) seen)
                 (cons f (-distinct-step (rest s) (conj seen f))))))))
       coll seen))))

;; `(distinct coll)` — drop all duplicates, first occurrence wins, lazily
;; (composes with an infinite source). Structural `=` via a persistent
;; seen-set (so strings/collections dedupe); O(1) amortized membership.
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
        ;; Lazy: seen-set -distinct-step. O(n) total via the persistent set.
        (-distinct-step coll #{}))))

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
;; D-134 cluster 4 — sequence helpers (Pattern A; recursion for
;; interpose/zipmap/interleave).
;; ----------------------------------------------------------------

;; `(empty? coll)` — true when coll has no items (nil counts as empty).
(def empty?
  (fn* [coll] (not (seq coll))))

;; `(fnil f x)` / `(fnil f x y)` / `(fnil f x y z)` — wrap f so its first
;; 1/2/3 args are replaced by the defaults when nil; trailing args pass
;; through (the returned fn is variadic, matching Clojure).
(def fnil
  (fn* ([f x] (fn* [a & args] (apply f (if (nil? a) x a) args)))
       ([f x y] (fn* [a b & args] (apply f (if (nil? a) x a) (if (nil? b) y b) args)))
       ([f x y z] (fn* [a b c & args] (apply f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c) args)))))

;; Lazy collection engine for `interpose`. The second lazy boundary is
;; intentional: realizing an item does not pull its successor; requesting the
;; separator pulls that successor before exposing the separator, matching JVM
;; Clojure's `(drop 1 (interleave (repeat sep) coll))` timing.
(def ^:private -interpose-lazy
  (fn* [sep coll]
    (lazy-seq
      (let [s (seq coll)]
        (if s
          (cons (first s)
                (lazy-seq
                  (let [r (next s)]
                    (if r
                      (cons sep (-interpose-lazy sep r))
                      nil))))
          nil)))))

;; `(interpose sep)` / `(interpose sep coll)` — sep between consecutive items.
;; The 1-arg form is a stateful transducer (emit sep before every item except
;; the first); the 2-arg form is a lazy seq and composes with infinite inputs.
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
        (-interpose-lazy sep coll))))

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
;; ----------------------------------------------------------------

;; `(max-key f & xs)` — the x with the greatest (f x); ties keep the LATER-seen.
;; `(min-key …)` is the mirror. This reproduces clj's exact algorithm, which is
;; NOT a uniform reduce: the seed of the first two uses a STRICT compare while
;; the fold of the rest uses a NON-strict one. The two disagree only on IEEE
;; NaN keys — the seed picks the second operand, the fold keeps the accumulator —
;; and the suite pins those cases (e.g. `(min-key identity [##-Inf ##NaN 1])`
;; => ##NaN but `[##-Inf 1 ##NaN]` => ##-Inf). ≥1 x required, matching JVM.
(def max-key
  (fn* [f x & xs]
    (if (seq xs)
      (let* [y (first xs)
             kx (f x) ky (f y)
             gt (> kx ky)
             v0 (if gt x y) kv0 (if gt kx ky)]
        (loop [v v0 kv kv0 more (rest xs)]
          (if (seq more)
            (let* [w (first more) kw (f w)]
              (if (>= kw kv) (recur w kw (rest more)) (recur v kv (rest more))))
            v)))
      x)))

(def min-key
  (fn* [f x & xs]
    (if (seq xs)
      (let* [y (first xs)
             kx (f x) ky (f y)
             lt (< kx ky)
             v0 (if lt x y) kv0 (if lt kx ky)]
        (loop [v v0 kv kv0 more (rest xs)]
          (if (seq more)
            (let* [w (first more) kw (f w)]
              (if (<= kw kv) (recur w kw (rest more)) (recur v kv (rest more))))
            v)))
      x)))

;; `(flatten coll)` — the contents of any nested sequential as a single
;; flat SEQUENCE (matches JVM: a lazy seq, not a vector). Non-sequential
;; leaves are kept; an empty/non-sequential input yields an empty seq.
;; (cljw collapses the empty seq to nil — the empty-seq≡nil divergence,
;; D-164 — so `(flatten [])` is nil rather than `()`.)
(def flatten
  (fn* [coll]
    (filter (fn* [x] (not (sequential? x)))
            (rest (tree-seq sequential? seq coll)))))

;; `(reductions f coll)` / `(reductions f init coll)` — like reduce
;; but collects every intermediate; the 2-arg form seeds from the
;; first element, the 3-arg form from `init`. Lazy (JVM parity): carries
;; the running accumulator as `init` through the recursion instead of
;; re-deriving it with `(last acc)` per step. The old eager form used
;; `(reduce (conj acc (f (last acc) x)) [init])`, where `(last acc)` is
;; O(n) on the growing vector → O(n²) overall (100k elems ≈ 100 s). This
;; lazy + accumulator-threaded shape is JVM's own and is O(n). [refs: O-009]
(def reductions
  (fn*
    ([f coll]
      (lazy-seq
        (let [s (seq coll)]
          (if s
            (reductions f (first s) (rest s))
            (list (f))))))
    ([f init coll]
      (if (reduced? init)
        (list (unreduced init))
        (cons init
          (lazy-seq
            (let [s (seq coll)]
              (when s
                (reductions f (f init (first s)) (rest s))))))))))

;; ----------------------------------------------------------------
;; D-134 cluster 6 — trivial accessors (no compare dependency).
;; ----------------------------------------------------------------

;; `(second coll)` — the second item (nil if absent).
(def second (fn* [coll] (first (rest coll))))

;; `(ffirst coll)` — `(first (first coll))`.
(def ffirst (fn* [coll] (first (first coll))))

;; `(key e)` / `(val e)` — the key / value of a map entry. clj parity: both
;; require an actual map entry (`map-entry?`), NOT a plain 2-vector. cljw's map
;; entries are a distinct type — `(map-entry? (first {:a 1}))` → true while
;; `(map-entry? [:a 1])` → false — so `(key [:k :v])` / `(val nil)` throw a
;; catchable ClassCastException like clj, rather than indexing positionally.
;; (Map destructuring feeds real entries via `(first (seq some-map))`, unaffected.)
;; java.util.Map$Entry / clojure.lang.IMapEntry on a deftype / reify: its
;; getKey/getValue (or key/val) route here (host_interface MAP_ENTRY), so `key`
;; / `val` below reach a user entry type the way clj's `(.getKey ^Map$Entry e)`
;; does. A native MapEntry keeps the positional fast path.
(defprotocol IMapEntry (-key [e]) (-val [e]))

(def key (fn* [e] (if (map-entry? e) (if (vector? e) (nth e 0) (-key e)) (throw (ClassCastException. "key: not a map entry")))))
(def val (fn* [e] (if (map-entry? e) (if (vector? e) (nth e 1) (-val e)) (throw (ClassCastException. "val: not a map entry")))))

;; `(not-empty coll)` — coll if it has items, else nil.
(def not-empty (fn* [coll] (if (empty? coll) nil coll)))

;; `(take-last n coll)` — the last n items (eager).
;; `(seq …)` so an empty result is nil, not () — clj's take-last returns nil
;; when there is nothing to take (`(take-last 0 x)` / `(take-last 2 [])` => nil).
(def take-last
  (fn* [n coll] (seq (reverse (take n (reverse coll))))))

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
;; PERF: default order routes through the native stable sort (-sort-natural,
;; valueCompare, no per-element take/drop/conj churn); a custom comparator
;; re-enters eval per comparison so it stays on the .clj -msort. [refs: O-007]
(def sort
  (fn* ([coll] (-seq-or-empty (-sort-natural (vec coll))))
       ([comp coll] (-seq-or-empty (-msort (-comparator comp) (vec coll))))))

;; `(sort-by f coll)` — order by `(compare (f a) (f b))`. `(sort-by f comp coll)`
;; — order by `(comp (f a) (f b))`. Stable. Returns a SEQ (see `sort`).
;; PERF: 2-arg default order precomputes keys once (mapv f) and runs the native
;; stable key sort (-sort-by-keys, valueCompare, no per-comparison f/eval
;; reentry); a custom comparator (3-arg) stays on the .clj -msort. [refs: O-010]
(def sort-by
  (fn* ([f coll]
        (let [v (vec coll)]
          (-seq-or-empty (-sort-by-keys (mapv f v) v))))
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
;; are lazy index walks; butlast drops the final element.
;; ----------------------------------------------------------------

;; Lazy collection engine for `map-indexed`. Preserve source chunks like JVM
;; Clojure while carrying the absolute index across chunk boundaries.
(def ^:private -map-indexed-lazy
  (fn* [f idx coll]
    (lazy-seq
      (let [s (seq coll)]
        (if s
          (if (chunked-seq? s)
            (let [size (cljw.internal/__chunk-count s)
                  b (chunk-buffer size)]
              (loop [i 0]
                (when (< i size)
                  (chunk-append b (f (+ idx i) (cljw.internal/__chunk-nth s i)))
                  (recur (inc i))))
              (chunk-cons b (-map-indexed-lazy f (+ idx size) (chunk-rest s))))
            (cons (f idx (first s))
                  (-map-indexed-lazy f (inc idx) (rest s))))
          nil)))))

;; `(map-indexed f coll)` — lazy map passing (index, item) to f.
(def map-indexed
  (fn* ([f]
        ;; transducer arity: stateful index starting at 0
        (fn* [rf]
          (let [iv (volatile! -1)]
            (fn* ([] (rf))
                 ([result] (rf result))
                 ([result input] (rf result (f (vswap! iv inc) input)))))))
       ([f coll]
        ;; Returns a lazy SEQ and walks non-indexed inputs sequentially (O(n)).
        ;; [refs: O-011]
        (-map-indexed-lazy f 0 coll))))

;; Lazy collection engine for `keep-indexed`. The inner loop skips runs of nil
;; results without building recursive function frames; emitted tails re-enter
;; through the lazy-seq boundary.
(def ^:private -keep-indexed-lazy
  (fn* [f idx coll]
    (lazy-seq
      ((fn* [i xs]
         (let [s (seq xs)]
           (when s
             (if (chunked-seq? s)
               (let [size (cljw.internal/__chunk-count s)
                     b (chunk-buffer size)]
                 (loop [j 0]
                   (when (< j size)
                     (let [v (f (+ i j) (cljw.internal/__chunk-nth s j))]
                       (when (not (nil? v)) (chunk-append b v)))
                     (recur (inc j))))
                 (chunk-cons b (-keep-indexed-lazy f (+ i size) (chunk-rest s))))
               (let [v (f i (first s))]
                 (if (nil? v)
                   (recur (inc i) (rest s))
                   (cons v (-keep-indexed-lazy f (inc i) (rest s)))))))))
       idx coll))))

;; `(keep-indexed f)` / `(keep-indexed f coll)` — like map-indexed but drops
;; nil results. The 1-arg form is a stateful transducer (running index); the
;; 2-arg form returns a lazy SEQ (JVM parity).
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
        ;; Sequential O(n) walk; no eager intermediate vector. [refs: O-011]
        (-keep-indexed-lazy f 0 coll))))

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
       ([n x]
        ;; Repeat.create accepts a long count; conversion precedes realization.
        (let [n (long n)]
          (lazy-seq (if (> n 0) (cons x (repeat (dec n) x)) nil))))))

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

;; `char-name-string` / `char-escape-string` — clojure.core's char→name and
;; char→escape-sequence tables (maps, callable as fns; a char not in the table
;; yields nil). Match clj exactly. (cljw's own printer escapes chars in Zig;
;; these are the user-facing data.)
(def char-name-string
  {\newline "newline"
   \tab "tab"
   \space "space"
   \backspace "backspace"
   \formfeed "formfeed"
   \return "return"})

(def char-escape-string
  {\newline "\\n"
   \tab "\\t"
   \return "\\r"
   \" "\\\""
   \\ "\\\\"
   \formfeed "\\f"
   \backspace "\\b"})

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
    ;; Validate and capture the initial seq at invocation, as Cycle.create does.
    (let [s (seq coll)]
      (lazy-seq
        (when s
          (-concat2 s (cycle s)))))))

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

;; `counted?`, `reversible?`, `seqable?` and `indexed?` are primitives: each is
;; `(instance? <interface> x)` over the interface_membership SSOT, so a deftype
;; or reify declaring the interface answers too.
;; Numeric / ident predicates (clj-source-faithful). `rational?` = exact
;; non-float; the ident family keys on keyword/symbol + `namespace` for the
;; qualified/simple split.
(def rational? (fn* [x] (or (integer? x) (ratio? x) (decimal? x))))
(def ident? (fn* [x] (or (keyword? x) (symbol? x))))
(def simple-ident? (fn* [x] (and (ident? x) (not (namespace x)))))
(def qualified-ident? (fn* [x] (boolean (and (ident? x) (namespace x) true))))
(def simple-symbol? (fn* [x] (and (symbol? x) (not (namespace x)))))
(def qualified-symbol? (fn* [x] (boolean (and (symbol? x) (namespace x) true))))
(def simple-keyword? (fn* [x] (and (keyword? x) (not (namespace x)))))
(def qualified-keyword? (fn* [x] (boolean (and (keyword? x) (namespace x) true))))

(defn namespace-munge
  "Convert a Clojure namespace name to a legal Java package name."
  [ns]
  (.replace (str ns) \- \_))

;; `munge` escapes every character illegal in a Java identifier as a `_TOKEN_`
;; (the inverse of clojure.repl/demunge). clj routes through Compiler.munge;
;; cljw carries the same char-map here. The map is a cljw implementation
;; detail (clj has no `clojure.core/char-map`), so it stays ^:private.
(def ^:private munge-char-map
  {\- "_", \: "_COLON_", \+ "_PLUS_", \> "_GT_", \< "_LT_", \= "_EQ_",
   \~ "_TILDE_", \! "_BANG_", \@ "_CIRCA_", \# "_SHARP_", \' "_SINGLEQUOTE_",
   \" "_DOUBLEQUOTE_", \% "_PERCENT_", \^ "_CARET_", \& "_AMPERSAND_",
   \* "_STAR_", \| "_BAR_", \{ "_LBRACE_", \} "_RBRACE_", \[ "_LBRACK_",
   \] "_RBRACK_", \/ "_SLASH_", \\ "_BSLASH_", \? "_QMARK_"})

(defn munge
  "Munges a name string or symbol into a legal Java identifier, escaping each
  special character as a `_TOKEN_`. Returns the same type as its argument."
  [s]
  ((if (symbol? s) symbol str)
   (apply str (map (fn [c] (get munge-char-map c c)) (str s)))))
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
;; `(-spread arglist)` — flatten the trailing seq of a `list*`/`apply`-style
;; arglist: the last element is a seq spliced in, the rest stay as-is. Top-level
;; recursive (a named local fn is unavailable in this bootstrap layer, D-147).
(def -spread
  (fn* [arglist]
    (cond
      (nil? arglist) nil
      (nil? (next arglist)) (seq (first arglist))
      :else (cons (first arglist) (-spread (next arglist))))))
;; `(list* a* tail)` — prepend the leading args onto the final seq arg.
;; Explicit 1-4 arg forms are the common cases; the 5+ arm spreads the rest.
(def list*
  (fn* ([args] (seq args))
       ([a args] (cons a args))
       ([a b args] (cons a (cons b args)))
       ([a b c args] (cons a (cons b (cons c args))))
       ([a b c d & more] (cons a (cons b (cons c (cons d (-spread more))))))))
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

;; `(splitv-at n coll)` — `[(into [] (take n) coll) (drop n coll)]` (1.12). Only
;; the FIRST part is a vector (the "v"); the second is the drop SEQ, matching clj
;; (which returns a [PersistentVector, ChunkedSeq], not two vectors).
(def splitv-at
  (fn* [n coll] [(vec (take n coll)) (drop n coll)]))

;; `(partitionv n [step [pad]] coll)` — like `partition` but each chunk is a
;; vector. Lazy. JVM parity: clojure.core/partitionv (1.12).
(def partitionv
  (fn* ([n coll] (partitionv n n coll))
       ([n step coll]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (let [p (vec (take n s))]
                (if (= (count p) n)
                  (cons p (partitionv n step (drop step s)))
                  nil))
              nil))))
       ([n step pad coll]
        (lazy-seq
          (let [s (seq coll)]
            (if s
              (let [p (vec (take n s))]
                (if (= (count p) n)
                  (cons p (partitionv n step pad (drop step s)))
                  (list (vec (take n (concat p pad))))))
              nil))))))

;; `(partitionv-all n [step] coll)` — a lazy seq of vector partitions, the last
;; possibly shorter than `n` (the vector-returning `partition-all`). JVM parity:
;; clojure.core/partitionv-all (1.12).
(def partitionv-all
  (fn* ([n coll] (partitionv-all n n coll))
       ([n step coll] (map vec (partition-all n step coll)))))

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
;; ----------------------------------------------------------------

(defprotocol IPersistentCollection (-count [c]) (-cons [c x]) (-empty [c]))
(defprotocol Seqable (-seq [c]))
(defprotocol IReduce (-reduce [c f]))
(defprotocol ISeq (-first [s]) (-rest [s]) (-next [s]))
(defprotocol ILookup (-lookup [c k]))
(defprotocol Indexed (-nth [c i]))
(defprotocol Associative (-assoc [c k v]) (-contains-key? [c k]) (-entry-at [c k]))
(defprotocol IPersistentMap (-without [m k]) (-keys [m]) (-vals [m]) (-assoc-ex [m k v]))
(defprotocol IPersistentSet (-disjoin [s k]))
;; Editable / transient collection family (D-286, F-013 definition-derived).
;; A deftype declaring these (flatland.ordered's OrderedSet/Transient* types)
;; registers + dispatches its methods. LOAD-LEVEL: cljw's native conj!/assoc!/
;; persistent!/disj! consult of a typed_instance transient + `into`/`-editable?`
;; typed_instance detection are a tracked off-critical-path follow-up (D-369);
;; `(ordered-set …)` rides the plain conj path, not transients (see D-286 note).
(defprotocol IEditableCollection (-as-transient [c]))
(defprotocol ITransientCollection (-conj! [c x]) (-persistent! [c]))
(defprotocol ITransientAssociative (-assoc! [c k v]))
(defprotocol ITransientMap (-without! [m k]))
(defprotocol ITransientSet (-disjoin! [s k]) (-tset-contains? [s k]))
(defprotocol ITransientVector (-assoc-n! [c i v]) (-pop! [c]))
(defprotocol Reversible (-rseq [c]))
;; `-sorted-comparator` (not `-comparator` — that name is already the sort
;; predicate-coercion helper at L1159; a collision broke `(sort > …)`).
(defprotocol Sorted (-sorted-comparator [c]) (-entry-key [c e]) (-sorted-seq [c asc]) (-sorted-seq-from [c k asc]))
;; D-280d6/d7: load-level for a deftype that is callable (IFn) / metadata-carrying
;; (IObj). The macro registers invoke→-invoke, meta→-meta, withMeta→-with-meta;
;; calling the instance as a fn + meta/with-meta consulting these are follow-ups.
(defprotocol IFn (-invoke [f]) (-apply-to [f args]))
(defprotocol IObj (-meta [o]) (-with-meta [o m]))
;; D-307: the deref-able interface family. A deftype implementing
;; clojure.lang.IDeref/IPending (e.g. core.memoize's RetryingDelay) registers
;; deref→-deref / isRealized→-realized?; `deref`/`@` and `realized?` consult
;; these for a typed_instance (stm.zig), mirroring the IObj meta consult.
(defprotocol IDeref (-deref [o]))
(defprotocol IPending (-realized? [o]))
;; D-400: kvreduce → -kv-reduce; reduce-kv consults it via cljw.internal/__kv-reduce-or
;; before its keys fallback. 3-arity timed deref → -blocking-deref; the deref
;; primitive's (deref x ms timeout-val) arity dispatches it (stm.zig).
(defprotocol IKVReduce (-kv-reduce [m f init]))
;; java.lang.Comparable deftype supertype (instaparse): compareTo →
;; -compare-to; `compare` consults it for a typed_instance (math.zig).
(defprotocol Comparable (-compare-to [a b]))
;; IPersistentVector deftype-supertype slots (instaparse, D-400 composite):
;; assocN/length register here (registration-level; bodies delegate via
;; dot-calls). Distinct from the native vector's instance? membership.
(defprotocol IPersistentVector (-assoc-n [v i x]) (-length [v]))
;; java.lang.CharSequence deftype supertype (instaparse's Segment):
;; length/charAt/subSequence register here (registration-level).
(defprotocol CharSequence (-cs-length [s]) (-char-at [s i]) (-sub-sequence [s start end]))
(defprotocol IBlockingDeref (-blocking-deref [o ms timeout-val]))
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
;; Thin wrapper over the cljw.internal/__satisfies? primitive, which consults x's
;; TypeDescriptor (typed_instance / reified_instance / native-Tag
;; default registry) for a method entry naming the protocol.
(def satisfies?
  (fn* [protocol x] (cljw.internal/__satisfies? protocol x)))

;; `(extends? protocol atype)` — true iff atype (a type, e.g. a defrecord/
;; deftype name or (cljw.internal/__native-type :tag)) carries the protocol. The
;; type-level counterpart of satisfies?: satisfies? takes a value, extends?
;; takes the type directly.
(def extends?
  (fn* [protocol atype] (cljw.internal/__extends? protocol atype)))

;; `(extend atype & proto+mmaps)` — the runtime protocol-extension fn that the
;; extend-type / extend-protocol macros are sugar over. `atype` is a type value
;; (a deftype/defrecord name or (class …)); each (protocol method-map) pair
;; installs onto it, where the map is {:method-kw fn}. Mirrors the macro's
;; `(cljw.internal/__extend-type! atype proto [["m" fn] …])` lowering, built from the map
;; at runtime. clojure.core/extend (used directly by libs that assemble impl
;; maps dynamically, e.g. clojure.tools.reader).
(def extend
  (fn* [atype & proto+mmaps]
    (loop [pairs (seq proto+mmaps)]
      (when pairs
        (cljw.internal/__extend-type! atype (first pairs)
          (reduce-kv (fn* [acc k v] (conj acc [(name k) v])) [] (second pairs)))
        (recur (nnext pairs))))))

;; `(destructure bindings)` — expand the destructuring forms in a binding vector
;; into plain-symbol bindings (gensym temps + nth/get/seq), suitable for `let*`.
;; The public binding-expander macro authors call (clojure.core/destructure;
;; kezban's `letm`, etc.). cljw reimplements clj's algorithm with three
;; substitutions: `reduce1`→`reduce`; the seq→map coercion uses `(apply hash-map …)`
;; / `{}` in place of `clojure.lang.PersistentArrayMap/createAsIfByAssoc`/`EMPTY`;
;; `ident?` in place of `(instance? clojure.lang.Named …)`. No upstream text reproduced.
(def destructure
  (fn* [bindings]
    (let [bents (partition 2 bindings)
          pb (fn pb [bvec b v]
               (let [pvec
                     (fn [bvec b val]
                       (let [gvec (gensym "vec__")
                             gseq (gensym "seq__")
                             gfirst (gensym "first__")
                             has-rest (some #{'&} b)]
                         (loop [ret (let [ret (conj bvec gvec val)]
                                      (if has-rest
                                        (conj ret gseq (list `seq gvec))
                                        ret))
                                n 0
                                bs b
                                seen-rest? false]
                           (if (seq bs)
                             (let [firstb (first bs)]
                               (cond
                                 (= firstb '&) (recur (pb ret (second bs) gseq)
                                                      n (nnext bs) true)
                                 (= firstb :as) (pb ret (second bs) gvec)
                                 :else (if seen-rest?
                                         (throw (ex-info "Unsupported binding form, only :as can follow & parameter" {}))
                                         (recur (pb (if has-rest
                                                      (conj ret gfirst (list `first gseq)
                                                            gseq (list `next gseq))
                                                      ret)
                                                    firstb
                                                    (if has-rest gfirst (list `nth gvec n nil)))
                                                (inc n) (next bs) seen-rest?))))
                             ret))))
                     pmap
                     (fn [bvec b v]
                       (let [gmap (gensym "map__")
                             defaults (:or b)]
                         (loop [ret (-> bvec (conj gmap) (conj v)
                                        (conj gmap) (conj `(if (seq? ~gmap)
                                                             (if (next ~gmap)
                                                               (apply hash-map ~gmap)
                                                               (if (seq ~gmap) (first ~gmap) {}))
                                                             ~gmap))
                                        ((fn [ret] (if (:as b) (conj ret (:as b) gmap) ret))))
                                bes (let [transforms
                                          (reduce
                                            (fn [transforms mk]
                                              (if (keyword? mk)
                                                (let [mkns (namespace mk)
                                                      mkn (name mk)]
                                                  (cond (= mkn "keys") (assoc transforms mk (fn* [k] (keyword (or mkns (namespace k)) (name k))))
                                                        (= mkn "syms") (assoc transforms mk (fn* [k] (list `quote (symbol (or mkns (namespace k)) (name k)))))
                                                        (= mkn "strs") (assoc transforms mk str)
                                                        :else transforms))
                                                transforms))
                                            {} (keys b))]
                                      (reduce
                                        (fn [bes entry]
                                          (reduce (fn* [m mk] (assoc m mk ((val entry) mk)))
                                                  (dissoc bes (key entry))
                                                  ((key entry) bes)))
                                        (dissoc b :as :or) transforms))]
                           (if (seq bes)
                             (let [bb (key (first bes))
                                   bk (val (first bes))
                                   local (if (ident? bb) (with-meta (symbol nil (name bb)) (meta bb)) bb)
                                   bv (if (contains? defaults local)
                                        (list `get gmap bk (defaults local))
                                        (list `get gmap bk))]
                               (recur (if (ident? bb)
                                        (-> ret (conj local bv))
                                        (pb ret bb bv))
                                      (next bes)))
                             ret))))]
                 (cond
                   (symbol? b) (-> bvec (conj b) (conj v))
                   (vector? b) (pvec bvec b v)
                   (map? b) (pmap bvec b v)
                   :else (throw (ex-info (str "Unsupported binding form: " b) {})))))
          process-entry (fn* [bvec b] (pb bvec (first b) (second b)))]
      (if (every? symbol? (map first bents))
        bindings
        (reduce process-entry [] bents)))))

;; `(class x)` — the type of x as an interned type value (ADR-0059):
;; native types render as Long / String / PersistentVector, user records
;; as their name; (class nil) → nil. Interned, so (= (class 5) (class 6))
;; is true and a class is a valid map key (group-by class).
(def class (fn* [x] (cljw.internal/__class x)))

;; `(class? x)` — true iff x is a class object (what (class …) returns).
(def class? (fn* [x] (cljw.internal/__class? x)))

;; `(type x)` — (:type (meta x)) when present, else (class x).
(def type (fn* [x] (or (:type (meta x)) (class x))))

;; `(resolve sym)` — the Var sym names in the current namespace (or the
;; named ns when qualified), or nil. Returns a var_ref that derefs to the
;; Var's value and prints #'ns/name.
;; `(resolve sym)` / `(resolve env sym)` — resolve a symbol to its Var (or
;; class), nil if unresolved. The 2-arg form takes a local-binding env (e.g.
;; macro `&env`); a symbol that names a local resolves to nil (clj parity).
(def resolve (fn* ([sym] (cljw.internal/__resolve sym))
                  ([env sym] (if (contains? env sym) nil (cljw.internal/__resolve sym)))))

;; Multimethod introspection — thin fn wrappers over the kernel primitives
;; (defmulti / defmethod are macros in macro_transforms; prefer-method is a clj FN
;; — see below.) `methods` → dispatch-val→method map; `get-method` → the method (or
;; nil); `remove-method` → the multifn; `prefers` → the prefer table.
(def methods (fn* [multifn] (cljw.internal/__methods multifn)))
(def get-method (fn* [multifn dispatch-val] (cljw.internal/__get-method multifn dispatch-val)))
(def remove-method (fn* [multifn dispatch-val] (cljw.internal/__remove-method! multifn dispatch-val)))
(def prefers (fn* [multifn] (cljw.internal/__prefers multifn)))
;; `prefer-method` is a FN in clj (D-373 audit: cljw had it as a needless macro —
;; its args are all values, no quoting — which broke higher-order use). Now a fn so
;; `(map (partial prefer-method mf) …)` / passing it works, matching clj.
(def prefer-method (fn* [multifn x y] (cljw.internal/__prefer-method! multifn x y)))

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
;; in `s`. The whole scan runs in one `re-find-all` Zig pass (O-035): a single
;; ThreadList reused across all matches, no per-match `[match start end]` Value
;; round-trip through the interpreter loop. Returns nil on no match (clj parity
;; via `re-find-all`'s empty → nil). Capture-group vectors land when groups do.
(def re-seq
  (fn* [re s]
    (re-find-all re s)))

;; `(re-matcher re s)` — a stateful java.util.regex.Matcher over `re` + `s`.
;; A non-string CharSequence (e.g. instaparse's Segment deftype) is coerced
;; via str.
(def re-matcher
  (fn* [re s]
    (.matcher re (if (string? s) s (str s)))))

;; `(re-groups m)` — the groups of the matcher's last match: the whole match
;; for a group-less pattern, else `[whole g1 g2 …]`.
(def re-groups
  (fn* [m]
    (let [gc (.groupCount m)]
      (if (zero? gc)
        (.group m)
        (loop [ret [] c 0]
          (if (<= c gc)
            (recur (conj ret (.group m c)) (inc c))
            ret))))))

;; `(re-find m)` / `(re-find re s)` — the matcher 1-arity advances the cursor
;; (`.find`) and returns `(re-groups m)`; the 2-arity delegates to the rt
;; primitive (`cljw.internal/__re-find`).
(def re-find
  (fn*
    ([m] (when (.find m) (re-groups m)))
    ([re s] (cljw.internal/__re-find re s))))

;; ----------------------------------------------------------------
;; Ad-hoc hierarchies — make-hierarchy / derive / underive / isa? /
;; parents / ancestors / descendants over a global hierarchy.
;; The global hierarchy is an atom (cljw has no alter-var-root).
;; Class supertypes of String are exposed through __class-parents.
;; Map entries are
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
  (fn* ([tag parent]
        ;; clj's 2-arity is STRICTER than its 3-arity, and the difference is
        ;; real rather than an oversight. Verified against the oracle:
        ;;   (derive ::a :b)                    -> throws (parent not namespaced)
        ;;   (derive (make-hierarchy) ::a :b)   -> SUCCEEDS
        ;; The global hierarchy is shared across every namespace, so an
        ;; un-namespaced parent there would let one library's :shape collide
        ;; with another's; a hierarchy VALUE you passed in is your own.
        ;;
        ;; The global overload calls namespace on parent before derive;
        ;; Class parents therefore throw, unlike Class *children* of the
        ;; three-argument overload. Both global tags must be namespaced.
        (when-not (or (symbol? parent) (keyword? parent))
          (throw (ClassCastException.
                   (str "derive: parent must be a named symbol or keyword, got " (pr-str parent)))))
        (when-not (namespace parent)
          (throw (ex-info (str "derive: parent must be namespaced, got " (pr-str parent)) {})))
        (when-not (or (class? tag)
                      (and (or (symbol? tag) (keyword? tag)) (namespace tag)))
          (throw (ex-info (str "derive: tag must be a class or a namespaced symbol/keyword, got "
                               (pr-str tag))
                          {})))
        (swap! -global-hierarchy derive tag parent) nil)
       ([h tag parent]
        ;; The 3-arity permits a Class tag but requires a Named parent.
        ;; It does not require the parent to be namespaced.
        (when-not (or (class? tag) (symbol? tag) (keyword? tag))
          (throw (ex-info (str "derive: tag must be a class, symbol or keyword, got " (pr-str tag)) {})))
        (when-not (or (symbol? parent) (keyword? parent))
          (throw (ex-info (str "derive: parent must be a symbol or keyword, got " (pr-str parent)) {})))
        ;; clj: self-derive → AssertionError; a non-map hierarchy field →
        ;; NullPointerException (it invokes the field as a fn). Both throw here
        ;; (exception-Kind divergence is AD-007). The 2-arity global path always
        ;; passes a valid hierarchy, so those guards never fire on it.
        (when (= tag parent)
          (throw (ex-info (str "(not= tag parent) — cannot derive " tag " from itself") {})))
        (when-not (and (map? (:parents h)) (map? (:descendants h)) (map? (:ancestors h)))
          (throw (ex-info "derive: hierarchy must have map :parents / :descendants / :ancestors" {})))
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
            (and (class? child) (class? parent) (cljw.internal/__class-isa? child parent))
            (contains? (get (:ancestors h) child) parent)
            (and (vector? parent) (vector? child)
                 (= (count parent) (count child))
                 (loop [ret true i 0]
                   (if (or (not ret) (= i (count parent)))
                     ret
                     (recur (isa? h (nth child i) (nth parent i)) (inc i)))))))))

(def parents
  (fn* ([tag] (parents (deref -global-hierarchy) tag))
       ([h tag] (let [explicit (get (:parents h) tag)
                       native (cljw.internal/__class-parents tag)]
                   (not-empty (reduce conj (or explicit #{}) native))))))

(def ancestors
  (fn* ([tag] (ancestors (deref -global-hierarchy) tag))
       ([h tag] (let [explicit (get (:ancestors h) tag)
                       native (cljw.internal/__class-parents tag)]
                   (not-empty (reduce conj (or explicit #{}) native))))))

(def descendants
  (fn* ([tag] (descendants (deref -global-hierarchy) tag))
       ([h tag]
        ;; clj: a class tag → UnsupportedOperationException (the class hierarchy
        ;; is open, not enumerable). cljw class values are class? too.
        (if (class? tag)
          (throw (ex-info "Can't get descendants of classes" {}))
          (not-empty (get (:descendants h) tag))))))

(def underive
  (fn* ([tag parent] (swap! -global-hierarchy underive tag parent) nil)
       ([h tag parent]
        ;; clj: a non-map (:parents h) → NullPointerException. Match as a throw
        ;; (AD-007). The 2-arity global path always passes a valid hierarchy.
        (when-not (map? (:parents h))
          (throw (ex-info "underive: hierarchy must have a map :parents" {})))
        (let [pm (:parents h)
              cps (if (get pm tag) (disj (get pm tag) parent) #{})
              new-parents (if (not-empty cps) (assoc pm tag cps) (dissoc pm tag))
              deriv-seq (flatten (map (fn* [e] (cons (nth e 0) (interpose (nth e 0) (nth e 1))))
                                      (seq new-parents)))]
          (if (contains? (get pm tag) parent)
            (reduce (fn* [hh pr] (derive hh (nth pr 0) (nth pr 1)))
                    (make-hierarchy) (partition 2 deriv-seq))
            h)))))

;; print-method (D-370, ADR-0127): the user-extensible print multimethod. The
;; native pr/prn/print/pr-str path consults it behind an any-override dirty flag —
;; `(defmethod print-method T [o w] …)` customises T's printing. Dispatches on
;; (class x); the :default delegates to the native printer (`cljw.internal/__print-method-default`
;; writes o's native render into the writer handle w), so a method that recurses
;; `(print-method child w)` lands on either another override or the native default.
;; The consult only fires for a type with a NON-default method, so the no-override
;; case pays zero clojure calls (ADR-0127 B2 dirty flag). Placed after
;; `-global-hierarchy` (the defmulti constructor references it).
(defmulti print-method (fn* [x w] (class x)))
(defmethod print-method :default [o w] (cljw.internal/__print-method-default o w))

;; `(doc sym)` — print a Var's documentation (name / arglists / docstring)
;; in clojure.repl/doc's format (D-187 part 2). The Var-metadata surface
;; (D-183) makes this the user-facing payoff: `(defn f "d" [x] x)` then
;; `(doc f)` shows the docstring. cljw has no `clojure.repl` ns yet, so this
;; lives in core (always referred); the `clojure.repl` home is a later
;; structural refinement. `print-doc` formats off `(meta var-ref)`; the
;; qualified name comes from `(str var-ref)` (`#'ns/name`) minus the `#'`.
;; doc / dir / apropos / find-doc live in the bundled `clojure.repl` (their
;; clj home) — the interactive REPL refers them into `user` (clojure.main
;; parity); scripts require clojure.repl explicitly. The early in-core copies
;; (pre-D-305, when vars carried no :doc) were removed with D-513.

;; `(send a f & args)` / `(send-off a f & args)` — dispatch an action to an
;; agent (clj 1.0). Both route the action fn through `bound-fn*` so the action
;; re-establishes the DISPATCHING thread's dynamic bindings before it runs on the
;; agent's action thread (clj's binding conveyance): `(binding [*v* x] (send a
;; (fn [_] *v*)))` sees `x`, not the var's root. `bound-fn*` captures at dispatch
;; time (the calling thread) and the worker replays it. `send`/`send-off` differ
;; only by executor pool in clj; cljw's first slice shares one, so both wrap the
;; SAME conveyance point (Single-Source-Lever) over the `__send`/`__send-off`
;; enqueue primitives. `bound-fn*` is defined later in this file → forward-declared
;; here (covers `future-call` below too).
(declare bound-fn*)
(defn send
  "Dispatch an action to an agent. Returns the agent immediately. Subsequently,
  in a thread from a thread pool, the state of the agent will be set to the value
  of: (apply action-fn state-of-agent args)."
  [a f & args]
  (apply cljw.internal/__send a (bound-fn* f) args))
(defn send-off
  "Dispatch a potentially blocking action to an agent. Returns the agent
  immediately. Subsequently, in a separate thread, the state of the agent will be
  set to the value of: (apply action-fn state-of-agent args)."
  [a f & args]
  (apply cljw.internal/__send-off a (bound-fn* f) args))

;; `tap>` / `add-tap` / `remove-tap` — clj 1.10 debugging fan-out (D-502).
;; clj uses a daemon thread + a bounded ArrayBlockingQueue; cljw has no
;; java.util.concurrent, so an agent (send-off → a real worker thread) carries
;; the async, non-blocking delivery — tap> returns true and never blocks the
;; caller. A per-tap try/catch plus the agent's :error-handler keep one faulty
;; tap from dropping the others (clj catches Throwable per tap too).
(defonce ^:private tapset (atom #{}))
(defonce ^:private tap-agent (agent nil :error-handler (fn [_ _] nil)))

(defn add-tap
  "Adds f, a fn of one argument, to the tap set. f will be called with anything
  sent via tap>. f may block briefly but will never impede tap>. Remember f to
  remove-tap."
  [f]
  (swap! tapset conj f)
  nil)

(defn remove-tap
  "Remove f from the tap set."
  [f]
  (swap! tapset disj f)
  nil)

(defn tap>
  "Sends x to any taps. Will not block. Returns true."
  [x]
  (send-off tap-agent
            (fn [_]
              (doseq [t @tapset]
                (try (t x) (catch Throwable _ nil)))
              nil))
  true)

;; `(flush)` — flush the current `*out*` writer VALUE (ADR-0138). clj flushes
;; the bound output stream; cljw's `*out*` is a first-class writer value whose
;; `.flush` is a no-op for the stdout sink but real for a buffered/string sink.
(defn flush
  "Flushes the output stream that is the current value of *out*."
  []
  (.flush *out*)
  nil)

;; `(future-call f)` — the fn behind the `future` macro (clj 1.1). The `future`
;; macro expands to `(future-call (fn* [] body))`, so `future-call` is the single
;; BINDING-CONVEYANCE point (clj parity): it wraps the thunk with `bound-fn*`,
;; which captures the CREATING thread's dynamic bindings and re-establishes them
;; in the worker before the body runs — `(binding [*v* x] @(future *v*))` sees
;; `x`, not the var's root. `pmap`/`pcalls`/`pvalues` route through `future`, so
;; they convey too. (`bound-fn*` is forward-declared above, at `send`.)
(defn future-call
  "Takes a function of no args and yields a future object that will invoke the
  function in another thread, caching the result for deref/@."
  [f]
  (cljw.internal/__future-call (bound-fn* f)))

;; `(load-string s)` — sequentially read+eval every form in s, return the last
;; value (clj 1.0). Each form is read only after the previous one ran, as
;; `require` loads a file, so a `(ns …)` in s governs how its later forms read
;; (`::kw`, syntax-quote) and the caller's ns is restored afterwards. Empty
;; string → nil.
(defn load-string
  "Sequentially read and evaluate the set of forms contained in the string."
  [s]
  (cljw.internal/__load-source "NO_SOURCE_PATH" s))

;; `(load-file name)`: read+eval every form in the file at path `name`,
;; returning the last form's value (clj 1.0). Same form-at-a-time loader as
;; `load-string`, labelled with `name` so errors and `:file` meta name the
;; file, with `*file*` bound to `name`.
(defn load-file
  "Sequentially read and evaluate the set of forms contained in the file."
  [name]
  (binding [*file* name]
    (cljw.internal/__load-source name (slurp name))))


;; `(definline name & decl)` — mainline defines an `:inline`-carrying fn (a
;; compiler hint cljw has no analogue for: no inline compilation pass), so
;; the observable surface — a callable fn Var — is exactly defn's.
(defmacro definline
  "Experimental - like defn, but will be used as a macro by the compiler when
  it is called at the head of a form. In ClojureWasm the fn definition is the
  whole behaviour (no inline compilation), so this is defn."
  [name & decl]
  (list* 'defn name decl))

;; `(memfn name & args)` — a fn wrapping an instance method call (clj 1.0).
;; `args` are PARAMETER names (not values): (memfn substring s e) → a 3-arg fn
;; (fn [target s e] (. target (substring s e))). clj type-hints the target to
;; avoid reflection; cljw needs no hint (no reflective dispatch), so it is dropped.
(defmacro memfn
  "Expands into a fn that takes an object plus args and calls the named instance
  method on the object with those args."
  [name & args]
  (let [t (gensym "target")]
    `(fn [~t ~@args] (. ~t (~name ~@args)))))

;; `(xml-seq root)` — depth-first seq over clojure.xml-shaped element maps,
;; descending through each element's `:content` (clj 1.0); pure over tree-seq.
(defn xml-seq
  "A tree seq on the xml elements as per clojure.xml/parse."
  [root]
  (tree-seq (complement string?) (comp seq :content) root))

;; `(pmap f coll & colls)` / `(pcalls & fns)` — PARALLEL map / parallel calls
;; (D-224), clj's exact impl: each element's `(f x)` runs on its own
;; `future` (a real OS thread); a `step`/`drop n` bounded look-ahead (n =
;; processors+2) keeps the parallel computation AHEAD of consumption without
;; realizing the whole result — semi-lazy, like clj. Defined here (not with the
;; other seq fns) because it needs `future`/`lazy-seq`/`if-let`/named-`fn`.
(defn pmap
  ([f coll]
   (let [n (+ 2 (.availableProcessors (Runtime/getRuntime)))
         rets (map (fn [x] (future (f x))) coll)
         step (fn step [vs fs]
                (lazy-seq
                  (if-let [s (seq fs)]
                    (cons (deref (first vs)) (step (rest vs) (rest s)))
                    (map deref vs))))]
     (step rets (drop n rets))))
  ([f coll & colls]
   (let [step (fn step [cs]
                (lazy-seq
                  (let [ss (map seq cs)]
                    (when (every? identity ss)
                      (cons (map first ss) (step (map rest ss)))))))]
     (pmap (fn [args] (apply f args)) (step (cons coll colls))))))
(defn pcalls [& fns] (pmap (fn [g] (g)) fns))

;; `(pvalues & exprs)` — clj's parallel-eval of each expr: expands to `pcalls`
;; over thunks, so each expr runs in parallel via `pmap`'s futures (D-246).
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

;; `(with-bindings* binding-map f & args)` — push thread bindings (keys are Vars,
;; `#'name`) for the dynamic extent of `(apply f args)`, popping in a finally.
;; The Zig push/pop-thread-bindings primitives install/remove one BindingFrame so
;; `Var.deref` (and the renderer's *print-* reads) see the bound values.
(defn with-bindings* [binding-map f & args]
  (push-thread-bindings binding-map)
  (try
    (apply f args)
    (finally
      (pop-thread-bindings))))

;; `(with-bindings binding-map body…)` — macro form over `with-bindings*`.
(defmacro with-bindings [binding-map & body]
  `(with-bindings* ~binding-map (fn* [] ~@body)))

;; `(bound-fn* f)` — capture the current thread bindings; the returned fn
;; re-establishes them around each call to `f`, so a fn handed to another thread
;; / callback sees the dynamic environment of its creation (clj parity).
(defn bound-fn* [f]
  (let [bindings (get-thread-bindings)]
    (fn* [& args]
      (apply with-bindings* bindings f args))))

;; `(bound-fn body…)` — sugar for `(bound-fn* (fn body…))`.
(defmacro bound-fn [& fntail]
  `(bound-fn* (fn* ~@fntail)))

;; Bind a MathContext so every BigDecimal operation observes significant-digit
;; precision and the requested rounding mode (not just division).
(defmacro with-precision [precision & body]
  (let [rounding? (= :rounding (first body))
        mode (second body)
        body (if rounding? (nnext body) body)
        mode-expr (when rounding?
                    (symbol "java.math.RoundingMode" (name mode)))]
    `(binding [*math-context* ~(if rounding?
                                  `(java.math.MathContext. ~precision ~mode-expr)
                                  `(java.math.MathContext. ~precision))]
       ~@body)))

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

;; `(with-in-str s & body)` — evaluate body with `*in*` bound to a reader over
;; the string `s`, so `read-line` / `line-seq` read from `s` (D-414). Mirrors
;; clojure.core/with-in-str (JVM binds a LineNumberingPushbackReader over a
;; java.io.StringReader; cljw uses the host `cljw.internal/__string-reader`). Placed with the
;; other `with-*` macros — `defmacro` is not usable as early as `read-line`.
(defmacro with-in-str [s & body]
  `(binding [*in* (cljw.internal/__in-reader ~s)]
     ~@body))

;; `(with-out-str & body)` — evaluate body with `*out*` bound to a fresh
;; string-backed writer, then return everything written to it as a String
;; (the body's own value is discarded). ADR-0138: a plain `binding` rebind of
;; the `*out*` writer VALUE — no threadlocal capture lane. Mirrors
;; clojure.core/with-out-str (JVM binds a java.io.StringWriter).
(defmacro with-out-str [& body]
  `(let [w# (cljw.internal/__string-writer)]
     (binding [*out* w#] ~@body)
     (cljw.internal/__writer->str w#)))

(defmacro time
  "Evaluates expr and prints the time it took. Returns the value of expr."
  [expr]
  `(let [start# (System/nanoTime)
         ret# ~expr]
     (prn (str "Elapsed time: " (/ (double (- (System/nanoTime) start#)) 1000000.0) " msecs"))
     ret#))

;; `(with-local-vars [x init ...] body…)` — bind each name to a FRESH anonymous
;; dynamic Var (ADR-0097 / D-237) thread-bound to its init for the body's extent,
;; popped in a finally. `var-get`/`var-set`/`@` operate on them inside the body.
;; The anon Var is gpa-owned + intentionally never freed (escape-safe; D-255
;; reclamation), minted by the `cljw.internal/__create-local-var` primitive.
(defmacro with-local-vars [bindings & body]
  (let [names (take-nth 2 bindings)
        inits (take-nth 2 (rest bindings))]
    `(let [~@(interleave names (map (fn* [_] (list (quote cljw.internal/__create-local-var))) names))]
       (push-thread-bindings (hash-map ~@(interleave names inits)))
       (try ~@body (finally (pop-thread-bindings))))))


;; `(requiring-resolve sym)` → resolve a qualified symbol, requiring its
;; namespace first if needed. Throws on a non-qualified symbol (clj parity).
;; Defined late: depends on qualified-symbol? / namespace / require / resolve.
(def requiring-resolve
  (fn* [sym]
    (if (qualified-symbol? sym)
      (do (require (symbol (namespace sym))) (resolve sym))
      (throw (IllegalArgumentException. (str "Not a qualified symbol: " sym))))))


;; --- Java arrays (ADR-0105 / D-287, ADR-0204) ---
;; An array has an element kind: `object-array` / `to-array` / `into-array` /
;; `make-array` hold any value, the typed constructors hold native elements
;; (byte i8 ... double f64). The cljw.internal/__array-make / __array-from /
;; __array-fill constructors are native, so an n-element array is one call.
;; Constructors convert like clj's RT.longArray and friends (wrap, truncate);
;; `aset` is strict (clj's "argument type mismatch"). Arrays use identity
;; equality.

(defn- -array-elems
  "A vector or array holding `x`'s elements, the input of `__array-from`."
  [x] (if (or (vector? x) (array? x)) x (vec x)))

(defn- -array-from
  "size-or-seq → array of `kind`. A number makes n default slots; otherwise
  each element of the seqable is converted to the kind."
  [kind size-or-seq]
  (if (number? size-or-seq)
    (cljw.internal/__array-make kind (long size-or-seq))
    (cljw.internal/__array-from kind (-array-elems size-or-seq) nil)))

(defn- -array-from2
  "size + init-val-or-seq → array of `kind` (the 2-arg ctor form). A
  `sequential?` init is copied (`size` slots, the rest left at the default);
  any other init fills every slot. Uniform across kinds, so unlike clj there
  is no per-type Number/Character overload accident: `(byte-array 3 65)` /
  `(char-array 3 65)` fill here but throw on the JVM (AD-036)."
  [kind size init]
  (if (sequential? init)
    (cljw.internal/__array-from kind (-array-elems init) (long size))
    (cljw.internal/__array-fill (cljw.internal/__array-make kind (long size)) init)))

;; object-array has NO clj 2-arg form (clj throws an arity error) — stays 1-arg.
(defn object-array  [x] (-array-from :object x))
;; The typed ctors take `([size-or-seq] [size init-val-or-seq])` (clj parity).
(defn int-array     ([x] (-array-from :int x))     ([n init] (-array-from2 :int n init)))
(defn long-array    ([x] (-array-from :long x))    ([n init] (-array-from2 :long n init)))
(defn double-array  ([x] (-array-from :double x))  ([n init] (-array-from2 :double n init)))
(defn float-array   ([x] (-array-from :float x))   ([n init] (-array-from2 :float n init)))
(defn short-array   ([x] (-array-from :short x))   ([n init] (-array-from2 :short n init)))
(defn byte-array    ([x] (-array-from :byte x))    ([n init] (-array-from2 :byte n init)))
(defn char-array    ([x] (-array-from :char x))    ([n init] (-array-from2 :char n init)))
(defn boolean-array ([x] (-array-from :boolean x)) ([n init] (-array-from2 :boolean n init)))

(defn make-array
  "Allocate an object array. The `type` arg is accepted but ignored: cljw has
  no Class objects, and `(make-array Long n)` is a `Long[]` on the JVM too.
  Multi-dim builds nested arrays."
  ([type len] (cljw.internal/__array-make :object len))
  ([type d & more]
   (let [a (cljw.internal/__array-make :object d)]
     (dotimes [i d] (aset a i (apply make-array type more)))
     a)))

(defn to-array
  "coll → an object array of its elements (clj returns Object[])."
  [coll] (-array-from :object (-array-elems coll)))

(defn bytes?
  "Returns true if x is a byte array."
  [x] (and (array? x) (= :byte (cljw.internal/__array-kind x))))

(defn into-array
  "coll → an object array; the optional leading `type` is accepted and
  ignored (a boxed `Long[]` on the JVM is an object array here too)."
  ([coll] (to-array coll))
  ([type coll] (to-array coll)))

;; aset-* typed setters: the value is coerced as clj's `(int v)` / `(byte v)`
;; ... do (a range check, not a wrap), then stored.
(defn aset-int
  ([a i v] (aset a i (int v)))
  ([a i j & more] (apply aset-int (aget a i) j more)))
(defn aset-long
  ([a i v] (aset a i (long v)))
  ([a i j & more] (apply aset-long (aget a i) j more)))
(defn aset-float
  ([a i v] (aset a i (float v)))
  ([a i j & more] (apply aset-float (aget a i) j more)))
(defn aset-double
  ([a i v] (aset a i (double v)))
  ([a i j & more] (apply aset-double (aget a i) j more)))
(defn aset-boolean
  ([a i v] (aset a i (boolean v)))
  ([a i j & more] (apply aset-boolean (aget a i) j more)))
(defn aset-byte
  ([a i v] (aset a i (byte v)))
  ([a i j & more] (apply aset-byte (aget a i) j more)))
(defn aset-short
  ([a i v] (aset a i (short v)))
  ([a i j & more] (apply aset-short (aget a i) j more)))
(defn aset-char
  ([a i v] (aset a i (char v)))
  ([a i j & more] (apply aset-char (aget a i) j more)))

(defmacro amap
  "Like clojure.core/amap: map `expr` over array `a`, binding each index to
  `idx` and `a` to `ret` (a clone being mutated)."
  [a idx ret expr]
  `(let [a# ~a
         ~ret (aclone a#)]
     (dotimes [~idx (alength a#)]
       (aset ~ret ~idx ~expr))
     ~ret))

(defmacro areduce
  "Like clojure.core/areduce: reduce over array `a`, `ret` accumulating from
  `init`, `idx` the current index."
  [a idx ret init expr]
  `(let [a# ~a]
     (loop [~idx 0 ~ret ~init]
       (if (< ~idx (alength a#))
         (recur (inc ~idx) ~expr)
         ~ret))))

;; ---------------------------------------------------------------------------
;; proxy — cljw has no JVM class hierarchy to extend, so `proxy` supports a
;; REGISTERED, closed-per-build set of base classes (D-298). The runtime cells
;; live in cljw.proxy; this is the OCP expansion layer. WHAT + contract only —
;; rationale (single-thread ThreadLocal semantics, why a registry) is in memory.
;; ---------------------------------------------------------------------------

(defn- proxy-threadlocal-expansion
  "Expander for (proxy [ThreadLocal] [] (initialValue [] body)). Emits a
   construction of the cljw.proxy ThreadLocal cell whose initialValue is the
   given 0-arg body. requiring-resolve keeps cljw.proxy off the analyze-time
   path and loads it on first use (the bundled-load-safe pattern)."
  [ctor-args methods]
  (let [init (methods 'initialValue)]
    (when-not (and (empty? ctor-args) init)
      (throw (ex-info "proxy [ThreadLocal] takes no super-args and requires an (initialValue [] ...) method"
                      {:proxy/base 'ThreadLocal :methods (vec (keys methods))})))
    `((requiring-resolve 'cljw.proxy/threadlocal-cell) (fn ~@init))))

(def ^:private proxy-base-registry
  "OCP extension point (D-298): base-class symbol -> expander
   (fn [ctor-args method-map] -> form). A base absent here is unsupported, and
   `proxy` raises rather than silently mis-expanding. Add a base by adding an
   entry (and a cell in cljw.proxy) — the `proxy` macro body never changes."
  {'ThreadLocal           proxy-threadlocal-expansion
   'java.lang.ThreadLocal proxy-threadlocal-expansion})

(defmacro proxy
  "Construct an instance of a REGISTERED proxyable base class with the given
   method overrides. Unlike JVM `proxy`, cljw's base set is closed per build
   (see proxy-base-registry): an unregistered base is a compile-time error, not
   a deep JVM class extension. Shape:
     (proxy [Base] [super-args] (method-name [params*] body)+)."
  {:arglists '([class-and-interfaces args & fs])}
  [bases ctor-args & fns]
  (let [base     (first bases)
        expander (get proxy-base-registry base)
        methods  (into {} (map (fn [f] [(first f) (rest f)])) fns)]
    (when-not expander
      (throw (ex-info (str "proxy against " base " is not part of ClojureWasm. "
                           "Supported base classes: " (pr-str (vec (keys proxy-base-registry)))
                           ". Extending arbitrary JVM classes needs deep class extension cljw does not provide.")
                      {:proxy/base base})))
    (expander ctor-args methods)))

(defn Throwable->map
  "Constructs a data representation for a caught exception with keys:
    :cause - root cause message
    :via   - cause chain, each {:type (simple class symbol) :message :data :at}
    :trace - root cause's frames
    :data  - root cause ex-data
  cljw exceptions are ex-info values (no JVM Throwable), so :type is the simple
  class name (AD-003) and :trace / per-via :at are cljw-shaped frame maps
  {:ns :fn :file :line :column} (ADR-0140), NOT JVM [class method file line]
  4-vectors (AD-033). A never-thrown ex-info has no frames, so :trace / :at are
  omitted (absent, never empty)."
  [e]
  (let [via (loop [acc [] t e] (if t (recur (conj acc t) (ex-cause t)) acc))
        root (peek via)
        base (fn [t]
               (merge {:type (symbol (.getName (class t)))}
                      (when-let [msg (ex-message t)] {:message msg})
                      (when-let [d (ex-data t)] {:data d})
                      (when-let [at (first (stack-trace t))] {:at at})))
        root-trace (stack-trace root)]
    (merge {:via (vec (map base via))}
           (when-let [rmsg (ex-message root)] {:cause rmsg})
           (when (seq root-trace) {:trace (vec root-trace)})
           (when-let [d (ex-data root)] {:data d}))))

;; `default-data-readers` — the built-in tagged-literal readers as data (clj
;; parity: values are the reader-fn VARS). cljw's reader wires #inst/#uuid
;; natively, so this map exists for the CONSUMERS of the var (edn/reader
;; libraries walking it, user code merging *data-readers*). requiring-resolve
;; loads the two thin nses at the very END of core (clj's own ordering —
;; they depend on core vars defined above; measured: sub-ms shims).
(def default-data-readers
  "Default map of data reader functions provided by Clojure. May be
  overridden by binding *data-readers*."
  ;; Values are call-time-resolving fns, not the reader VARS clj holds:
  ;; resolving eagerly would require the shim nses during the bootstrap
  ;; AOT (a known minefield — bundled .clj loads are strict at cache_gen)
  ;; and cost startup. Consumers CALL the values; the fn-vs-Var class is
  ;; the one visible nuance (D-563c note).
  {'inst (fn [form] ((requiring-resolve 'clojure.instant/read-instant-date) form))
   'uuid (fn [form] ((requiring-resolve 'clojure.uuid/default-uuid-reader) form))})

;; `monitor-enter` / `monitor-exit` are Zig primitives (locking.zig). On the JVM
;; they are special forms, so the generated core_meta.clj has no row for them;
;; their docs are attached here, into the var meta `(:doc (meta v))` reads.
(alter-meta! (var monitor-enter) merge
             {:doc "Acquires the monitor of x, returning nil. The caller is responsible
  for the matching monitor-exit; prefer `locking`, which releases on both
  normal and error exit. Throws if x is nil."
              :arglists (quote ([x]))})
(alter-meta! (var monitor-exit) merge
             {:doc "Releases the monitor of x, returning nil. Pairs with monitor-enter.
  Throws if x is nil."
              :arglists (quote ([x]))})
