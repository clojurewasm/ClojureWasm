// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Bootstrap — loads and evaluates core.clj to register macros and core functions.
//!
//! Pipeline: source string -> Reader -> Forms -> Analyzer -> Nodes -> TreeWalk eval
//! Each top-level form is analyzed and evaluated sequentially.
//! defmacro forms register macros in the Env for use by subsequent forms.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = @import("../reader/reader.zig").Reader;
const Form = @import("../reader/form.zig").Form;
const Analyzer = @import("../analyzer/analyzer.zig").Analyzer;
const Node = @import("../analyzer/node.zig").Node;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Env = @import("env.zig").Env;
const Namespace = @import("namespace.zig").Namespace;
const err = @import("error.zig");
const TreeWalk = @import("../evaluator/tree_walk.zig").TreeWalk;
const predicates_mod = @import("../builtins/predicates.zig");
const chunk_mod = @import("../compiler/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const vm_mod = @import("../vm/vm.zig");
const VM = vm_mod.VM;
const gc_mod = @import("gc.zig");
const builtin_collections = @import("../builtins/collections.zig");

/// Bootstrap error type.
pub const BootstrapError = error{
    ReadError,
    AnalyzeError,
    EvalError,
    CompileError,
    OutOfMemory,
};

/// Embedded core.clj source (compiled into binary).
const core_clj_source = @embedFile("../clj/clojure/core.clj");

/// Embedded clojure/test.clj source (compiled into binary).
const test_clj_source = @embedFile("../clj/clojure/test.clj");

/// Embedded clojure/walk.clj source (compiled into binary).
const walk_clj_source = @embedFile("../clj/clojure/walk.clj");

/// Embedded clojure/set.clj source (compiled into binary).
const set_clj_source = @embedFile("../clj/clojure/set.clj");

/// Embedded clojure/data.clj source (compiled into binary).
const data_clj_source = @embedFile("../clj/clojure/data.clj");

/// Embedded clojure/repl.clj source (compiled into binary).
const repl_clj_source = @embedFile("../clj/clojure/repl.clj");

/// Embedded clojure/java/io.clj source (compiled into binary).
const io_clj_source = @embedFile("../clj/clojure/java/io.clj");

/// Embedded clojure/pprint.clj source (compiled into binary).
const pprint_clj_source = @embedFile("../clj/clojure/pprint.clj");

/// Embedded clojure/stacktrace.clj source (compiled into binary).
const stacktrace_clj_source = @embedFile("../clj/clojure/stacktrace.clj");

/// Embedded clojure/zip.clj source (compiled into binary).
const zip_clj_source = @embedFile("../clj/clojure/zip.clj");

/// Embedded clojure/core/reducers.clj source (compiled into binary).
const reducers_clj_source = @embedFile("../clj/clojure/core/reducers.clj");

/// Embedded clojure/test/tap.clj source (compiled into binary).
const test_tap_clj_source = @embedFile("../clj/clojure/test/tap.clj");


/// Embedded clojure/instant.clj source (compiled into binary).
const instant_clj_source = @embedFile("../clj/clojure/instant.clj");

/// Embedded clojure/java/process.clj source (compiled into binary).
const process_clj_source = @embedFile("../clj/clojure/java/process.clj");

/// Embedded clojure/main.clj source (compiled into binary).
const main_clj_source = @embedFile("../clj/clojure/main.clj");

/// Embedded clojure/core/server.clj source (compiled into binary).
const server_clj_source = @embedFile("../clj/clojure/core/server.clj");


/// Embedded clojure/xml.clj source (compiled into binary).
const xml_clj_source = @embedFile("../clj/clojure/xml.clj");

/// Embedded clojure/spec/gen/alpha.clj source (compiled into binary).
const spec_gen_alpha_clj_source = @embedFile("../clj/clojure/spec/gen/alpha.clj");

/// Embedded clojure/spec/alpha.clj source (compiled into binary).
const spec_alpha_clj_source = @embedFile("../clj/clojure/spec/alpha.clj");

/// Embedded clojure/core/specs/alpha.clj source (compiled into binary).
const core_specs_alpha_clj_source = @embedFile("../clj/clojure/core/specs/alpha.clj");


/// Hot core function definitions re-evaluated via VM compiler after bootstrap (24C.5b, D73).
///
/// Two-phase bootstrap problem: core.clj is loaded via TreeWalk for fast startup
/// (~10ms). But this means transducer factories (map, filter, comp) return
/// TreeWalk closures. When these closures are called from a VM reduce loop,
/// each call goes through treewalkCallBridge — creating a new TreeWalk evaluator
/// per invocation (~200x slower than native VM dispatch).
///
/// Solution: After TreeWalk bootstrap, re-define only the hot-path functions
/// via the VM compiler. The transducer 1-arity forms (which return step functions
/// used inside reduce) are bytecoded; other arities delegate to the original
/// TreeWalk versions to minimize bytecode footprint and startup time.
///
/// Also includes get-in/assoc-in/update-in which delegate to Zig builtins
/// (__zig-get-in, __zig-assoc-in, __zig-update-in) for single-call path traversal.
///
/// Impact: transduce 2134ms -> 15ms (142x).
const hot_core_defs =
    // map, filter, comp: transducer arity returns bytecode closures.
    \\(defn filter
    \\  ([pred]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result] (rf result))
    \\       ([result input]
    \\        (if (pred input)
    \\          (rf result input)
    \\          result)))))
    \\  ([pred coll]
    \\   (__zig-lazy-filter pred coll)))
    \\(defn comp
    \\  ([] identity)
    \\  ([f] f)
    \\  ([f g]
    \\   (fn
    \\     ([] (f (g)))
    \\     ([x] (f (g x)))
    \\     ([x y] (f (g x y)))
    \\     ([x y z] (f (g x y z)))
    \\     ([x y z & args] (f (apply g x y z args)))))
    \\  ([f g & fs]
    \\   (reduce comp (list* f g fs))))
    \\(defn map
    \\  ([f]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result] (rf result))
    \\       ([result input]
    \\        (rf result (f input))))))
    \\  ([f coll]
    \\   (__zig-lazy-map f coll))
    \\  ([f c1 c2]
    \\   (lazy-seq
    \\    (let [s1 (seq c1) s2 (seq c2)]
    \\      (when (and s1 s2)
    \\        (cons (f (first s1) (first s2))
    \\              (map f (rest s1) (rest s2)))))))
    \\  ([f c1 c2 c3]
    \\   (lazy-seq
    \\    (let [s1 (seq c1) s2 (seq c2) s3 (seq c3)]
    \\      (when (and s1 s2 s3)
    \\        (cons (f (first s1) (first s2) (first s3))
    \\              (map f (rest s1) (rest s2) (rest s3)))))))
    \\  ([f c1 c2 c3 & colls]
    \\   (let [step (fn step [cs]
    \\                (lazy-seq
    \\                 (let [ss (map seq cs)]
    \\                   (when (every? identity ss)
    \\                     (cons (map first ss) (step (map rest ss)))))))]
    \\     (map #(apply f %) (step (conj colls c3 c2 c1))))))
    \\(defn get-in
    \\  ([m ks] (__zig-get-in m ks))
    \\  ([m ks not-found] (__zig-get-in m ks not-found)))
    \\(defn assoc-in [m ks v] (__zig-assoc-in m ks v))
    \\(defn update-in
    \\  ([m ks f] (__zig-update-in m ks f))
    \\  ([m ks f a] (__zig-update-in m ks f a))
    \\  ([m ks f a b] (__zig-update-in m ks f a b))
    \\  ([m ks f a b c] (__zig-update-in m ks f a b c))
    \\  ([m ks f a b c & args] (apply __zig-update-in m ks f a b c args)))
;

/// Higher-order functions that return Clojure closures.
/// These cannot be Zig builtin_fn (bare function pointers with no captured state).
/// Evaluated via VM bootstrap alongside hot_core_defs, producing bytecoded closures.
/// Order matters: preserving-reduced before cat, complement before remove.
const core_hof_defs =
    \\(defn constantly [x]
    \\  (fn [& args] x))
    \\(defn complement [f]
    \\  (fn [& args]
    \\    (not (apply f args))))
    \\(defn partial
    \\  ([f] f)
    \\  ([f arg1]
    \\   (fn
    \\     ([] (f arg1))
    \\     ([x] (f arg1 x))
    \\     ([x y] (f arg1 x y))
    \\     ([x y z] (f arg1 x y z))
    \\     ([x y z & args] (apply f arg1 x y z args))))
    \\  ([f arg1 arg2]
    \\   (fn
    \\     ([] (f arg1 arg2))
    \\     ([x] (f arg1 arg2 x))
    \\     ([x y] (f arg1 arg2 x y))
    \\     ([x y z] (f arg1 arg2 x y z))
    \\     ([x y z & args] (apply f arg1 arg2 x y z args))))
    \\  ([f arg1 arg2 arg3]
    \\   (fn
    \\     ([] (f arg1 arg2 arg3))
    \\     ([x] (f arg1 arg2 arg3 x))
    \\     ([x y] (f arg1 arg2 arg3 x y))
    \\     ([x y z] (f arg1 arg2 arg3 x y z))
    \\     ([x y z & args] (apply f arg1 arg2 arg3 x y z args))))
    \\  ([f arg1 arg2 arg3 & more]
    \\   (fn [& args] (apply f arg1 arg2 arg3 (concat more args)))))
    \\(defn juxt
    \\  ([f]
    \\   (fn
    \\     ([] [(f)])
    \\     ([x] [(f x)])
    \\     ([x y] [(f x y)])
    \\     ([x y z] [(f x y z)])
    \\     ([x y z & args] [(apply f x y z args)])))
    \\  ([f g]
    \\   (fn
    \\     ([] [(f) (g)])
    \\     ([x] [(f x) (g x)])
    \\     ([x y] [(f x y) (g x y)])
    \\     ([x y z] [(f x y z) (g x y z)])
    \\     ([x y z & args] [(apply f x y z args) (apply g x y z args)])))
    \\  ([f g h]
    \\   (fn
    \\     ([] [(f) (g) (h)])
    \\     ([x] [(f x) (g x) (h x)])
    \\     ([x y] [(f x y) (g x y) (h x y)])
    \\     ([x y z] [(f x y z) (g x y z) (h x y z)])
    \\     ([x y z & args] [(apply f x y z args) (apply g x y z args) (apply h x y z args)])))
    \\  ([f g h & fs]
    \\   (let [fs (list* f g h fs)]
    \\     (fn
    \\       ([] (reduce #(conj %1 (%2)) [] fs))
    \\       ([x] (reduce #(conj %1 (%2 x)) [] fs))
    \\       ([x y] (reduce #(conj %1 (%2 x y)) [] fs))
    \\       ([x y z] (reduce #(conj %1 (%2 x y z)) [] fs))
    \\       ([x y z & args] (reduce #(conj %1 (apply %2 x y z args)) [] fs))))))
    \\(defn every-pred
    \\  ([p]
    \\   (fn ep1
    \\     ([] true)
    \\     ([x] (boolean (p x)))
    \\     ([x y] (boolean (and (p x) (p y))))
    \\     ([x y z] (boolean (and (p x) (p y) (p z))))
    \\     ([x y z & args] (boolean (and (ep1 x y z)
    \\                                   (every? p args))))))
    \\  ([p1 p2]
    \\   (fn ep2
    \\     ([] true)
    \\     ([x] (boolean (and (p1 x) (p2 x))))
    \\     ([x y] (boolean (and (p1 x) (p1 y) (p2 x) (p2 y))))
    \\     ([x y z] (boolean (and (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z))))
    \\     ([x y z & args] (boolean (and (ep2 x y z)
    \\                                   (every? #(and (p1 %) (p2 %)) args))))))
    \\  ([p1 p2 p3]
    \\   (fn ep3
    \\     ([] true)
    \\     ([x] (boolean (and (p1 x) (p2 x) (p3 x))))
    \\     ([x y] (boolean (and (p1 x) (p1 y) (p2 x) (p2 y) (p3 x) (p3 y))))
    \\     ([x y z] (boolean (and (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z) (p3 x) (p3 y) (p3 z))))
    \\     ([x y z & args] (boolean (and (ep3 x y z)
    \\                                   (every? #(and (p1 %) (p2 %) (p3 %)) args))))))
    \\  ([p1 p2 p3 & ps]
    \\   (let [ps (list* p1 p2 p3 ps)]
    \\     (fn epn
    \\       ([] true)
    \\       ([x] (every? #(% x) ps))
    \\       ([x y] (every? #(and (% x) (% y)) ps))
    \\       ([x y z] (every? #(and (% x) (% y) (% z)) ps))
    \\       ([x y z & args] (boolean (and (epn x y z)
    \\                                     (every? #(every? % args) ps))))))))
    \\(defn some-fn
    \\  ([p]
    \\   (fn sp1
    \\     ([] nil)
    \\     ([x] (p x))
    \\     ([x y] (or (p x) (p y)))
    \\     ([x y z] (or (p x) (p y) (p z)))
    \\     ([x y z & args] (or (sp1 x y z)
    \\                         (some p args)))))
    \\  ([p1 p2]
    \\   (fn sp2
    \\     ([] nil)
    \\     ([x] (or (p1 x) (p2 x)))
    \\     ([x y] (or (p1 x) (p1 y) (p2 x) (p2 y)))
    \\     ([x y z] (or (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z)))
    \\     ([x y z & args] (or (sp2 x y z)
    \\                         (some #(or (p1 %) (p2 %)) args)))))
    \\  ([p1 p2 p3]
    \\   (fn sp3
    \\     ([] nil)
    \\     ([x] (or (p1 x) (p2 x) (p3 x)))
    \\     ([x y] (or (p1 x) (p1 y) (p2 x) (p2 y) (p3 x) (p3 y)))
    \\     ([x y z] (or (p1 x) (p1 y) (p1 z) (p2 x) (p2 y) (p2 z) (p3 x) (p3 y) (p3 z)))
    \\     ([x y z & args] (or (sp3 x y z)
    \\                         (some #(or (p1 %) (p2 %) (p3 %)) args)))))
    \\  ([p1 p2 p3 & ps]
    \\   (let [ps (list* p1 p2 p3 ps)]
    \\     (fn spn
    \\       ([] nil)
    \\       ([x] (some #(% x) ps))
    \\       ([x y] (some #(or (% x) (% y)) ps))
    \\       ([x y z] (some #(or (% x) (% y) (% z)) ps))
    \\       ([x y z & args] (or (spn x y z)
    \\                           (some #(some % args) ps)))))))
    \\(defn fnil
    \\  ([f x]
    \\   (fn
    \\     ([a] (f (if (nil? a) x a)))
    \\     ([a b] (f (if (nil? a) x a) b))
    \\     ([a b c] (f (if (nil? a) x a) b c))
    \\     ([a b c & ds] (apply f (if (nil? a) x a) b c ds))))
    \\  ([f x y]
    \\   (fn
    \\     ([a b] (f (if (nil? a) x a) (if (nil? b) y b)))
    \\     ([a b c] (f (if (nil? a) x a) (if (nil? b) y b) c))
    \\     ([a b c & ds] (apply f (if (nil? a) x a) (if (nil? b) y b) c ds))))
    \\  ([f x y z]
    \\   (fn
    \\     ([a b] (f (if (nil? a) x a) (if (nil? b) y b)))
    \\     ([a b c] (f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c)))
    \\     ([a b c & ds] (apply f (if (nil? a) x a) (if (nil? b) y b) (if (nil? c) z c) ds)))))
    \\(defn memoize [f]
    \\  (let [mem (atom {})]
    \\    (fn [& args]
    \\      (if-let [e (find (deref mem) args)]
    \\        (val e)
    \\        (let [ret (apply f args)]
    \\          (swap! mem assoc args ret)
    \\          ret)))))
    \\(defn bound-fn*
    \\  [f]
    \\  (let [bindings (get-thread-bindings)]
    \\    (fn [& args]
    \\      (apply with-bindings* bindings f args))))
    \\(defn completing
    \\  ([f] (completing f identity))
    \\  ([f cf]
    \\   (fn
    \\     ([] (f))
    \\     ([x] (cf x))
    \\     ([x y] (f x y)))))
    \\(defn comparator [pred]
    \\  (fn [x y]
    \\    (cond (pred x y) -1 (pred y x) 1 :else 0)))
    \\(defn accessor [s key]
    \\  (fn [m] (get m key)))
    \\(defn- preserving-reduced [rf]
    \\  (fn [a b]
    \\    (let [ret (rf a b)]
    \\      (if (reduced? ret)
    \\        (reduced ret)
    \\        ret))))
    \\(defn cat [rf]
    \\  (let [rrf (preserving-reduced rf)]
    \\    (fn
    \\      ([] (rf))
    \\      ([result] (rf result))
    \\      ([result input]
    \\       (reduce rrf result input)))))
    \\(defn halt-when
    \\  ([pred] (halt-when pred nil))
    \\  ([pred retf]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result]
    \\        (if (and (map? result) (contains? result ::halt))
    \\          (::halt result)
    \\          (rf result)))
    \\       ([result input]
    \\        (if (pred input)
    \\          (reduced {::halt (if retf (retf (rf result) input) input)})
    \\          (rf result input)))))))
    \\(defn dedupe
    \\  ([]
    \\   (fn [rf]
    \\     (let [pv (volatile! ::none)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [prior @pv]
    \\            (vreset! pv input)
    \\            (if (= prior input)
    \\              result
    \\              (rf result input))))))))
    \\  ([coll] (sequence (dedupe) coll)))
    \\(defn remove
    \\  ([pred] (filter (complement pred)))
    \\  ([pred coll]
    \\   (filter (complement pred) coll)))
;

/// Remaining core.clj functions: transducers, lazy-seq constructors, def constants,
/// destructure, pmap, etc. Evaluated after core_hof_defs.
const core_seq_defs =
    \\(defn concat
    \\  ([] (lazy-seq nil))
    \\  ([x] (lazy-seq x))
    \\  ([x y]
    \\   (lazy-seq
    \\    (let [s (seq x)]
    \\      (if s
    \\        (cons (first s) (concat (rest s) y))
    \\        y))))
    \\  ([x y & zs]
    \\   (let [cat (fn cat [xy zs]
    \\               (lazy-seq
    \\                (let [s (seq xy)]
    \\                  (if s
    \\                    (cons (first s) (cat (rest s) zs))
    \\                    (when zs
    \\                      (cat (first zs) (next zs)))))))]
    \\     (cat (concat x y) zs))))
    \\(defn iterate [f x]
    \\  (__zig-lazy-iterate f x))
    \\(defn range
    \\  ([] (iterate inc 0))
    \\  ([end] (range 0 end 1))
    \\  ([start end] (range start end 1))
    \\  ([start end step]
    \\   (if (and (integer? start) (integer? end) (integer? step))
    \\     (__zig-lazy-range start end step)
    \\     (lazy-seq
    \\      (cond
    \\        (and (pos? step) (< start end))
    \\        (cons start (range (+ start step) end step))
    \\        (and (neg? step) (> start end))
    \\        (cons start (range (+ start step) end step)))))))
    \\(defn repeat
    \\  ([x] (lazy-seq (cons x (repeat x))))
    \\  ([n x]
    \\   (take n (repeat x))))
    \\(defn repeatedly
    \\  ([f] (lazy-seq (cons (f) (repeatedly f))))
    \\  ([n f] (take n (repeatedly f))))
    \\(defn take
    \\  ([n]
    \\   (fn [rf]
    \\     (let [nv (volatile! n)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [cur @nv
    \\                nxt (vswap! nv dec)
    \\                res (if (pos? cur)
    \\                      (rf result input)
    \\                      result)]
    \\            (if (not (pos? nxt))
    \\              (ensure-reduced res)
    \\              res)))))))
    \\  ([n coll]
    \\   (__zig-lazy-take n coll)))
    \\(defn drop
    \\  ([n]
    \\   (fn [rf]
    \\     (let [nv (volatile! n)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [cur @nv]
    \\            (vswap! nv dec)
    \\            (if (pos? cur)
    \\              result
    \\              (rf result input))))))))
    \\  ([n coll]
    \\   (lazy-seq
    \\    (loop [i n s (seq coll)]
    \\      (if (if (> i 0) s nil)
    \\        (recur (- i 1) (next s))
    \\        s)))))
    \\(defn lazy-cat-helper [colls]
    \\  (when (seq colls)
    \\    (lazy-seq
    \\     (let [c (first colls)]
    \\       (if (seq c)
    \\         (cons (first c) (lazy-cat-helper (cons (rest c) (rest colls))))
    \\         (lazy-cat-helper (rest colls)))))))
    \\(defn cycle [coll]
    \\  (when (seq coll)
    \\    (lazy-seq
    \\     (lazy-cat-helper (repeat coll)))))
    \\(defn interleave
    \\  ([] (list))
    \\  ([c1] (lazy-seq c1))
    \\  ([c1 c2]
    \\   (lazy-seq
    \\    (let [s1 (seq c1) s2 (seq c2)]
    \\      (when (and s1 s2)
    \\        (cons (first s1) (cons (first s2)
    \\                               (interleave (rest s1) (rest s2))))))))
    \\  ([c1 c2 & colls]
    \\   (lazy-seq
    \\    (let [ss (map seq (cons c1 (cons c2 colls)))]
    \\      (when (every? identity ss)
    \\        (concat (map first ss) (apply interleave (map rest ss))))))))
    \\(defn interpose
    \\  ([sep]
    \\   (fn [rf]
    \\     (let [started (volatile! false)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (if @started
    \\            (let [sepr (rf result sep)]
    \\              (if (reduced? sepr)
    \\                sepr
    \\                (rf sepr input)))
    \\            (do
    \\              (vreset! started true)
    \\              (rf result input))))))))
    \\  ([sep coll]
    \\   (drop 1 (interleave (repeat sep) coll))))
    \\(defn partition
    \\  ([n coll]
    \\   (partition n n coll))
    \\  ([n step coll]
    \\   (loop [s (seq coll) acc (list)]
    \\     (let [chunk (take n s)]
    \\       (if (= (count chunk) n)
    \\         (recur (drop step s) (cons chunk acc))
    \\         (reverse acc)))))
    \\  ([n step pad coll]
    \\   (loop [s (seq coll) acc (list)]
    \\     (let [chunk (take n s)]
    \\       (if (= (count chunk) n)
    \\         (recur (drop step s) (cons chunk acc))
    \\         (if (seq chunk)
    \\           (reverse (cons (take n (concat chunk pad)) acc))
    \\           (reverse acc)))))))
    \\(defn partition-by
    \\  ([f]
    \\   (fn [rf]
    \\     (let [a (volatile! [])
    \\           pv (volatile! ::none)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result]
    \\          (let [result (if (zero? (count @a))
    \\                         result
    \\                         (let [v @a]
    \\                           (vreset! a [])
    \\                           (unreduced (rf result v))))]
    \\            (rf result)))
    \\         ([result input]
    \\          (let [pval @pv
    \\                val (f input)]
    \\            (vreset! pv val)
    \\            (if (or (identical? pval ::none)
    \\                    (= val pval))
    \\              (do (vswap! a conj input)
    \\                  result)
    \\              (let [v @a]
    \\                (vreset! a [])
    \\                (let [ret (rf result v)]
    \\                  (when-not (reduced? ret)
    \\                    (vswap! a conj input))
    \\                  ret)))))))))
    \\  ([f coll]
    \\   (loop [s (seq coll) acc (list) cur (list) prev nil started false]
    \\     (if s
    \\       (let [v (first s)
    \\             fv (f v)]
    \\         (if (if started (= fv prev) true)
    \\           (recur (next s) acc (cons v cur) fv true)
    \\           (recur (next s) (cons (reverse cur) acc) (list v) fv true)))
    \\       (if (seq cur)
    \\         (reverse (cons (reverse cur) acc))
    \\         (reverse acc))))))
    \\(defn distinct
    \\  ([]
    \\   (fn [rf]
    \\     (let [seen (volatile! #{})]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (if (contains? @seen input)
    \\            result
    \\            (do (vswap! seen conj input)
    \\                (rf result input))))))))
    \\  ([coll]
    \\   (loop [s (seq coll) seen #{} acc (list)]
    \\     (if s
    \\       (let [x (first s)]
    \\         (if (contains? seen x)
    \\           (recur (next s) seen acc)
    \\           (recur (next s) (conj seen x) (cons x acc))))
    \\       (reverse acc)))))
    \\(defn mapcat
    \\  ([f] (comp (map f) cat))
    \\  ([f coll]
    \\   ((fn step [cur remaining]
    \\      (lazy-seq
    \\       (if (seq cur)
    \\         (cons (first cur) (step (rest cur) remaining))
    \\         (let [s (seq remaining)]
    \\           (when s
    \\             (step (f (first s)) (rest s)))))))
    \\    nil coll))
    \\  ([f c1 c2]
    \\   (apply concat (map f c1 c2)))
    \\  ([f c1 c2 c3]
    \\   (apply concat (map f c1 c2 c3))))
    \\(defn map-indexed
    \\  ([f]
    \\   (fn [rf]
    \\     (let [i (volatile! -1)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (rf result (f (vswap! i inc) input)))))))
    \\  ([f coll]
    \\   (loop [s (seq coll) i 0 acc (list)]
    \\     (if s
    \\       (recur (next s) (+ i 1) (cons (f i (first s)) acc))
    \\       (reverse acc)))))
    \\(defn keep
    \\  ([f]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result] (rf result))
    \\       ([result input]
    \\        (let [v (f input)]
    \\          (if (nil? v)
    \\            result
    \\            (rf result v)))))))
    \\  ([f coll]
    \\   (lazy-seq
    \\    (when-let [s (seq coll)]
    \\      (if (chunked-seq? s)
    \\        (let [c (chunk-first s)
    \\              size (count c)
    \\              b (chunk-buffer size)]
    \\          (loop [i 0]
    \\            (when (< i size)
    \\              (let [x (f (nth c i))]
    \\                (when-not (nil? x)
    \\                  (chunk-append b x)))
    \\              (recur (inc i))))
    \\          (chunk-cons (chunk b) (keep f (chunk-rest s))))
    \\        (let [x (f (first s))]
    \\          (if (nil? x)
    \\            (keep f (rest s))
    \\            (cons x (keep f (rest s))))))))))
    \\(defn keep-indexed
    \\  ([f]
    \\   (fn [rf]
    \\     (let [iv (volatile! -1)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [i (vswap! iv inc)
    \\                v (f i input)]
    \\            (if (nil? v)
    \\              result
    \\              (rf result v))))))))
    \\  ([f coll]
    \\   (loop [s (seq coll) i 0 acc (list)]
    \\     (if s
    \\       (let [v (f i (first s))]
    \\         (if (nil? v)
    \\           (recur (next s) (+ i 1) acc)
    \\           (recur (next s) (+ i 1) (cons v acc))))
    \\       (reverse acc)))))
    \\(defn partition-all
    \\  ([n]
    \\   (fn [rf]
    \\     (let [a (volatile! [])]
    \\       (fn
    \\         ([] (rf))
    \\         ([result]
    \\          (let [result (if (zero? (count @a))
    \\                         result
    \\                         (let [v @a]
    \\                           (vreset! a [])
    \\                           (unreduced (rf result v))))]
    \\            (rf result)))
    \\         ([result input]
    \\          (vswap! a conj input)
    \\          (if (= n (count @a))
    \\            (let [v @a]
    \\              (vreset! a [])
    \\              (rf result v))
    \\            result))))))
    \\  ([n coll]
    \\   (loop [s (seq coll) acc (list)]
    \\     (let [chunk (take n s)]
    \\       (if (seq chunk)
    \\         (recur (drop n s) (cons chunk acc))
    \\         (reverse acc))))))
    \\(defn take-while
    \\  ([pred]
    \\   (fn [rf]
    \\     (fn
    \\       ([] (rf))
    \\       ([result] (rf result))
    \\       ([result input]
    \\        (if (pred input)
    \\          (rf result input)
    \\          (reduced result))))))
    \\  ([pred coll]
    \\   (lazy-seq
    \\    (let [s (seq coll)]
    \\      (when s
    \\        (when (pred (first s))
    \\          (cons (first s) (take-while pred (rest s)))))))))
    \\(defn drop-while
    \\  ([pred]
    \\   (fn [rf]
    \\     (let [dv (volatile! true)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [drop? @dv]
    \\            (if (and drop? (pred input))
    \\              result
    \\              (do
    \\                (vreset! dv nil)
    \\                (rf result input)))))))))
    \\  ([pred coll]
    \\   (loop [s (seq coll)]
    \\     (if s
    \\       (if (pred (first s))
    \\         (recur (next s))
    \\         s)
    \\       (list)))))
    \\(defn take-nth
    \\  ([n]
    \\   (fn [rf]
    \\     (let [iv (volatile! -1)]
    \\       (fn
    \\         ([] (rf))
    \\         ([result] (rf result))
    \\         ([result input]
    \\          (let [i (vswap! iv inc)]
    \\            (if (zero? (rem i n))
    \\              (rf result input)
    \\              result)))))))
    \\  ([n coll]
    \\   (lazy-seq
    \\    (when-let [s (seq coll)]
    \\      (cons (first s) (take-nth n (drop n s)))))))
    \\(defn replace
    \\  ([smap]
    \\   (map (fn [x] (if-let [e (find smap x)] (val e) x))))
    \\  ([smap coll]
    \\   (if (vector? coll)
    \\     (reduce (fn [v i]
    \\               (if-let [e (find smap (nth v i))]
    \\                 (assoc v i (val e))
    \\                 v))
    \\             coll (range (count coll)))
    \\     (map (fn [x] (if-let [e (find smap x)] (val e) x)) coll))))
    \\(defn random-sample
    \\  ([prob]
    \\   (filter (fn [_] (< (rand) prob))))
    \\  ([prob coll]
    \\   (filter (fn [_] (< (rand) prob)) coll)))
    \\(defn reductions
    \\  ([f coll]
    \\   (lazy-seq
    \\    (if-let [s (seq coll)]
    \\      (reductions f (first s) (rest s))
    \\      (list (f)))))
    \\  ([f init coll]
    \\   (if (reduced? init)
    \\     (list @init)
    \\     (cons init
    \\           (lazy-seq
    \\            (when-let [s (seq coll)]
    \\              (reductions f (f init (first s)) (rest s))))))))
    \\(defn tree-seq
    \\  [branch? children root]
    \\  (let [walk (fn walk [node]
    \\               (lazy-seq
    \\                (cons node
    \\                      (when (branch? node)
    \\                        (mapcat walk (children node))))))]
    \\    (walk root)))
    \\(defn xml-seq
    \\  [root]
    \\  (tree-seq
    \\   (complement string?)
    \\   (comp seq :content)
    \\   root))
    \\(defn iteration
    \\  [step & {:keys [somef vf kf initk]
    \\           :or {vf identity
    \\                kf identity
    \\                somef some?
    \\                initk nil}}]
    \\  ((fn next [ret]
    \\     (when (somef ret)
    \\       (cons (vf ret)
    \\             (when-some [k (kf ret)]
    \\               (lazy-seq (next (step k)))))))
    \\   (step initk)))
    \\(defn partitionv
    \\  ([n coll] (partitionv n n coll))
    \\  ([n step coll]
    \\   (lazy-seq
    \\    (let [s (seq coll)
    \\          p (vec (take n s))]
    \\      (when (= n (count p))
    \\        (cons p (partitionv n step (nthrest s step)))))))
    \\  ([n step pad coll]
    \\   (lazy-seq
    \\    (let [s (seq coll)
    \\          p (vec (take n s))]
    \\      (if (= n (count p))
    \\        (cons p (partitionv n step pad (nthrest s step)))
    \\        (when (seq p)
    \\          (list (vec (take n (concat p pad))))))))))
    \\(defn partitionv-all
    \\  ([n coll] (partitionv-all n n coll))
    \\  ([n step coll]
    \\   (lazy-seq
    \\    (let [s (seq coll)]
    \\      (when s
    \\        (let [p (vec (take n s))]
    \\          (cons p (partitionv-all n step (nthrest s step)))))))))
    \\(defn pmap
    \\  ([f coll]
    \\   (let [n (+ 2 (__available-processors))
    \\         rets (map (fn [x] (future (f x))) coll)
    \\         step (fn step [[x & xs :as vs] fs]
    \\                (lazy-seq
    \\                 (if-let [s (seq fs)]
    \\                   (cons (deref x) (step xs (rest s)))
    \\                   (map deref vs))))]
    \\     (step rets (drop n rets))))
    \\  ([f coll & colls]
    \\   (let [step (fn step [cs]
    \\                (lazy-seq
    \\                 (let [ss (map seq cs)]
    \\                   (when (every? identity ss)
    \\                     (cons (map first ss) (step (map rest ss)))))))]
    \\     (pmap (fn [args] (apply f args)) (step (cons coll colls))))))
    \\(defn pcalls
    \\  [& fns] (pmap (fn [f] (f)) fns))
    \\(defn- parse-impls [specs]
    \\  (loop [ret {} s specs]
    \\    (if (seq s)
    \\      (recur (assoc ret (first s) (take-while seq? (next s)))
    \\             (drop-while seq? (next s)))
    \\      ret)))
    \\(defn destructure [bindings]
    \\  (let [bents (partition 2 bindings)
    \\        pb (fn pb [bvec b v]
    \\             (let [pvec
    \\                   (fn [bvec b val]
    \\                     (let [gvec (gensym "vec__")
    \\                           gseq (gensym "seq__")
    \\                           gfirst (gensym "first__")
    \\                           has-rest (some #{'&} b)]
    \\                       (loop [ret (let [ret (conj bvec gvec val)]
    \\                                    (if has-rest
    \\                                      (conj ret gseq (list `seq gvec))
    \\                                      ret))
    \\                              n 0
    \\                              bs b
    \\                              seen-rest? false]
    \\                         (if (seq bs)
    \\                           (let [firstb (first bs)]
    \\                             (cond
    \\                               (= firstb '&) (recur (pb ret (second bs) gseq)
    \\                                                    n
    \\                                                    (nnext bs)
    \\                                                    true)
    \\                               (= firstb :as) (pb ret (second bs) gvec)
    \\                               :else (if seen-rest?
    \\                                       (throw (ex-info "Unsupported binding form, only :as can follow & parameter" {}))
    \\                                       (recur (pb (if has-rest
    \\                                                    (conj ret
    \\                                                          gfirst `(first ~gseq)
    \\                                                          gseq `(next ~gseq))
    \\                                                    ret)
    \\                                                  firstb
    \\                                                  (if has-rest
    \\                                                    gfirst
    \\                                                    (list `nth gvec n nil)))
    \\                                              (inc n)
    \\                                              (next bs)
    \\                                              seen-rest?))))
    \\                           ret))))
    \\                   pmap
    \\                   (fn [bvec b v]
    \\                     (let [gmap (gensym "map__")
    \\                           defaults (:or b)]
    \\                       (loop [ret (-> bvec (conj gmap) (conj v)
    \\                                      (conj gmap) (conj `(if (seq? ~gmap)
    \\                                                           (seq-to-map-for-destructuring ~gmap)
    \\                                                           ~gmap))
    \\                                      ((fn [ret]
    \\                                         (if (:as b)
    \\                                           (conj ret (:as b) gmap)
    \\                                           ret))))
    \\                              bes (let [transforms
    \\                                        (reduce
    \\                                         (fn [transforms mk]
    \\                                           (if (keyword? mk)
    \\                                             (let [mkns (namespace mk)
    \\                                                   mkn (name mk)]
    \\                                               (cond (= mkn "keys") (assoc transforms mk #(keyword (or mkns (namespace %)) (name %)))
    \\                                                     (= mkn "syms") (assoc transforms mk #(list `quote (symbol (or mkns (namespace %)) (name %))))
    \\                                                     (= mkn "strs") (assoc transforms mk str)
    \\                                                     :else transforms))
    \\                                             transforms))
    \\                                         {}
    \\                                         (keys b))]
    \\                                    (reduce
    \\                                     (fn [bes entry]
    \\                                       (reduce #(assoc %1 %2 ((val entry) %2))
    \\                                               (dissoc bes (key entry))
    \\                                               ((key entry) bes)))
    \\                                     (dissoc b :as :or)
    \\                                     transforms))]
    \\                         (if (seq bes)
    \\                           (let [bb (key (first bes))
    \\                                 bk (val (first bes))
    \\                                 local (if (ident? bb) (with-meta (symbol nil (name bb)) (meta bb)) bb)
    \\                                 bv (if (contains? defaults local)
    \\                                      (list `get gmap bk (defaults local))
    \\                                      (list `get gmap bk))]
    \\                             (recur (if (ident? bb)
    \\                                      (-> ret (conj local bv))
    \\                                      (pb ret bb bv))
    \\                                    (next bes)))
    \\                           ret))))]
    \\               (cond
    \\                 (symbol? b) (-> bvec (conj b) (conj v))
    \\                 (vector? b) (pvec bvec b v)
    \\                 (map? b) (pmap bvec b v)
    \\                 :else (throw (ex-info (str "Unsupported binding form: " b) {})))))
    \\        process-entry (fn [bvec b] (pb bvec (first b) (second b)))]
    \\    (if (every? symbol? (map first bents))
    \\      bindings
    \\      (reduce process-entry [] bents))))
    \\(def String 'String)
    \\(def Character 'Character)
    \\(def Number 'Number)
    \\(def Integer 'Integer)
    \\(def Long 'Long)
    \\(def Double 'Double)
    \\(def Float 'Float)
    \\(def Boolean 'Boolean)
    \\(def Object 'Object)
    \\(def Throwable 'Throwable)
    \\(def Exception 'Exception)
    \\(def RuntimeException 'RuntimeException)
    \\(def Comparable 'Comparable)
    \\(def ^:dynamic *math-context* nil)
    \\(def *assert* true)
    \\(def ^:private global-hierarchy (make-hierarchy))
    \\(def *clojure-version*
    \\  {:major 1 :minor 12 :incremental 0 :qualifier nil})
    \\(def ^:dynamic *warn-on-reflection* false)
    \\(def ^:dynamic *agent* nil)
    \\(def ^:dynamic *allow-unresolved-vars* false)
    \\(def ^:dynamic *reader-resolver* nil)
    \\(def ^:dynamic *suppress-read* false)
    \\(def ^:dynamic *compile-path* nil)
    \\(def ^:dynamic *fn-loader* nil)
    \\(def ^:dynamic *use-context-classloader* true)
    \\(def char-escape-string
    \\  {\newline "\\n"
    \\   \tab     "\\t"
    \\   \return  "\\r"
    \\   \"       "\\\""
    \\   \\       "\\\\"
    \\   \formfeed "\\f"
    \\   \backspace "\\b"})
    \\(def char-name-string
    \\  {\newline  "newline"
    \\   \tab      "tab"
    \\   \space    "space"
    \\   \backspace "backspace"
    \\   \formfeed "formfeed"
    \\   \return   "return"})
    \\(def default-data-readers
    \\  {'inst __inst-from-string
    \\   'uuid __uuid-from-string})
    \\(def *1 nil)
    \\(def *2 nil)
    \\(def *3 nil)
;

/// Load and evaluate core.clj in the given Env using two-phase bootstrap (D73).
///
/// Phase 1: Evaluate core.clj via TreeWalk for fast startup (~10ms).
///   All macros, vars, and functions are defined as TreeWalk closures.
///
/// Phase 2: Re-compile hot-path transducer functions (map, filter, comp,
///   get-in, assoc-in, update-in) and HOF closures (constantly, complement,
///   partial, juxt, etc.) via VM compiler. This produces bytecode closures
///   that run ~200x faster in VM reduce loops than TreeWalk closures.
///
/// Called after registerBuiltins. Temporarily switches to clojure.core namespace,
/// then re-refers all bindings into user namespace.
pub fn loadCore(allocator: Allocator, env: *Env) BootstrapError!void {
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };

    // Save current namespace and switch to clojure.core
    const saved_ns = env.current_ns;
    env.current_ns = core_ns;

    // Phase 1: Evaluate core.clj via TreeWalk (fast bootstrap, ~10ms).
    _ = try evalString(allocator, env, core_clj_source);

    // Phase 2: Re-compile transducer factory functions to bytecodes via VM.
    // Only 1-arity (transducer) forms are bytecoded; other arities delegate
    // to original TreeWalk versions to minimize memory/cache footprint.
    _ = try evalStringVMBootstrap(allocator, env, hot_core_defs);

    // Phase 2b: Define HOF closure utilities via VM (constantly, complement,
    // partial, juxt, every-pred, some-fn, fnil, memoize, etc.).
    _ = try evalStringVMBootstrap(allocator, env, core_hof_defs);

    // Phase 2c: Define remaining transducers, lazy-seq constructors, def constants
    // via VM (concat, iterate, range, repeat, partition, destructure, etc.).
    _ = try evalStringVMBootstrap(allocator, env, core_seq_defs);

    // Restore user namespace and re-refer all core bindings
    env.current_ns = saved_ns;
    syncNsVar(env);
    if (saved_ns) |user_ns| {
        var iter = core_ns.mappings.iterator();
        while (iter.next()) |entry| {
            user_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    // Note: print Var caches (*print-length*, *print-level*) are initialized
    // by restoreFromBootstrapCache() in the production path, not here.
    // loadCore is also used in tests with local arenas, so setting globals
    // here would create dangling pointers after the arena is freed.
}

/// Load and evaluate clojure/walk.clj in the given Env.
/// Creates the clojure.walk namespace and defines tree walker functions.
/// Re-refers walk bindings into user namespace for convenience.
pub fn loadWalk(allocator: Allocator, env: *Env) BootstrapError!void {
    // Create clojure.walk namespace
    const walk_ns = env.findOrCreateNamespace("clojure.walk") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    // Refer all clojure.core bindings into clojure.walk so core functions are available
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        walk_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    // Save current namespace and switch to clojure.walk
    const saved_ns = env.current_ns;
    env.current_ns = walk_ns;

    // Evaluate clojure/walk.clj (defines functions in clojure.walk)
    _ = try evalString(allocator, env, walk_clj_source);

    // Restore user namespace and re-refer walk bindings
    env.current_ns = saved_ns;
    syncNsVar(env);
    if (saved_ns) |user_ns| {
        var iter = walk_ns.mappings.iterator();
        while (iter.next()) |entry| {
            user_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }
}

/// Load and evaluate clojure/test.clj in the given Env.
/// Creates the clojure.test namespace and defines test macros (deftest, is, etc.).
/// Re-refers test bindings into user namespace for convenience.
pub fn loadTest(allocator: Allocator, env: *Env) BootstrapError!void {
    // Create clojure.test namespace
    const test_ns = env.findOrCreateNamespace("clojure.test") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    // Refer all clojure.core bindings into clojure.test so core functions are available
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        test_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    // Refer clojure.walk bindings (are macro uses postwalk-replace)
    if (env.findNamespace("clojure.walk")) |walk_ns| {
        var walk_iter = walk_ns.mappings.iterator();
        while (walk_iter.next()) |entry| {
            test_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    // Save current namespace and switch to clojure.test
    const saved_ns = env.current_ns;
    env.current_ns = test_ns;

    // Evaluate clojure/test.clj (defines macros/functions in clojure.test)
    _ = try evalString(allocator, env, test_clj_source);

    // Restore user namespace and re-refer test bindings
    env.current_ns = saved_ns;
    syncNsVar(env);
    if (saved_ns) |user_ns| {
        var iter = test_ns.mappings.iterator();
        while (iter.next()) |entry| {
            user_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }
}

/// Load and evaluate clojure/set.clj in the given Env.
/// Creates the clojure.set namespace and defines set operation functions.
/// Re-refers set bindings into user namespace for convenience.
pub fn loadSet(allocator: Allocator, env: *Env) BootstrapError!void {
    // Create clojure.set namespace
    const set_ns = env.findOrCreateNamespace("clojure.set") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    // Refer all clojure.core bindings into clojure.set so core functions are available
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        set_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    // Save current namespace and switch to clojure.set
    const saved_ns = env.current_ns;
    env.current_ns = set_ns;

    // Evaluate clojure/set.clj (defines functions in clojure.set)
    _ = try evalString(allocator, env, set_clj_source);

    // Restore user namespace and re-refer set bindings
    env.current_ns = saved_ns;
    syncNsVar(env);
    if (saved_ns) |user_ns| {
        var iter = set_ns.mappings.iterator();
        while (iter.next()) |entry| {
            user_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }
}

pub fn loadData(allocator: Allocator, env: *Env) BootstrapError!void {
    // Create clojure.data namespace
    const data_ns = env.findOrCreateNamespace("clojure.data") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    // Refer all clojure.core bindings into clojure.data
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        data_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    // Save current namespace and switch to clojure.data
    const saved_ns = env.current_ns;
    env.current_ns = data_ns;

    // Evaluate clojure/data.clj (defines functions in clojure.data)
    _ = try evalString(allocator, env, data_clj_source);

    // Restore namespace
    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/repl.clj in the given Env.
/// Creates the clojure.repl namespace and defines REPL utility functions
/// (doc, dir, source, apropos, find-doc, pst).
/// Re-refers repl bindings into user namespace for convenience.
pub fn loadRepl(allocator: Allocator, env: *Env) BootstrapError!void {
    // Create clojure.repl namespace
    const repl_ns = env.findOrCreateNamespace("clojure.repl") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    // Refer all clojure.core bindings into clojure.repl so core functions are available
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        repl_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    // Also refer clojure.string into clojure.repl (repl.clj requires it)
    if (env.findNamespace("clojure.string")) |string_ns| {
        repl_ns.setAlias("clojure.string", string_ns) catch {};
    }

    // Save current namespace and switch to clojure.repl
    const saved_ns = env.current_ns;
    env.current_ns = repl_ns;

    // Evaluate clojure/repl.clj (defines functions in clojure.repl)
    _ = try evalString(allocator, env, repl_clj_source);

    // Restore user namespace and re-refer repl bindings
    env.current_ns = saved_ns;
    syncNsVar(env);
    if (saved_ns) |user_ns| {
        var iter = repl_ns.mappings.iterator();
        while (iter.next()) |entry| {
            user_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }
}

/// Load and evaluate clojure/java/io.clj in the given Env.
/// Defines Coercions, IOFactory protocols and reader/writer/input-stream/output-stream.
/// The namespace already exists (builtins registered in registry.zig); this adds CLJ-level vars.
pub fn loadJavaIo(allocator: Allocator, env: *Env) BootstrapError!void {
    // Namespace already created by registry.zig with builtins
    const io_ns = env.findNamespace("clojure.java.io") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: clojure.java.io namespace not found", .{});
        return error.EvalError;
    };

    // Refer clojure.core bindings
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        io_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    // Refer clojure.string bindings (used in io.clj)
    if (env.findNamespace("clojure.string")) |str_ns| {
        var str_iter = str_ns.mappings.iterator();
        while (str_iter.next()) |entry| {
            io_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    const saved_ns = env.current_ns;
    env.current_ns = io_ns;

    _ = try evalString(allocator, env, io_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/pprint.clj in the given Env.
/// Defines print-table (pprint is a Zig builtin registered in registry.zig).
pub fn loadPprint(allocator: Allocator, env: *Env) BootstrapError!void {
    const pprint_ns = env.findOrCreateNamespace("clojure.pprint") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        pprint_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = pprint_ns;

    _ = try evalString(allocator, env, pprint_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

pub fn loadStacktrace(allocator: Allocator, env: *Env) BootstrapError!void {
    const st_ns = env.findOrCreateNamespace("clojure.stacktrace") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        st_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = st_ns;

    _ = try evalString(allocator, env, stacktrace_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

pub fn loadZip(allocator: Allocator, env: *Env) BootstrapError!void {
    const zip_ns = env.findOrCreateNamespace("clojure.zip") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        zip_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = zip_ns;

    _ = try evalString(allocator, env, zip_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/core/reducers.clj in the given Env.
/// Creates the clojure.core.reducers namespace with reduce, fold, CollFold,
/// monoid, and transformation functions (map, filter, etc.).
/// Requires clojure.walk and clojure.core.protocols to be loaded first.
pub fn loadReducers(allocator: Allocator, env: *Env) BootstrapError!void {
    const reducers_ns = env.findOrCreateNamespace("clojure.core.reducers") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        reducers_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = reducers_ns;

    _ = try evalString(allocator, env, reducers_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/test/tap.clj.
pub fn loadTestTap(allocator: Allocator, env: *Env) BootstrapError!void {
    const tap_ns = env.findOrCreateNamespace("clojure.test.tap") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        tap_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = tap_ns;

    _ = try evalString(allocator, env, test_tap_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/instant.clj.
pub fn loadInstant(allocator: Allocator, env: *Env) BootstrapError!void {
    const instant_ns = env.findOrCreateNamespace("clojure.instant") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        instant_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = instant_ns;

    _ = try evalString(allocator, env, instant_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/xml.clj.
pub fn loadXml(allocator: Allocator, env: *Env) BootstrapError!void {
    const xml_ns = env.findOrCreateNamespace("clojure.xml") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        xml_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = xml_ns;

    _ = try evalString(allocator, env, xml_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/java/process.clj.
pub fn loadProcess(allocator: Allocator, env: *Env) BootstrapError!void {
    const process_ns = env.findOrCreateNamespace("clojure.java.process") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        process_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = process_ns;

    _ = try evalString(allocator, env, process_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/main.clj.
pub fn loadMain(allocator: Allocator, env: *Env) BootstrapError!void {
    const main_ns = env.findOrCreateNamespace("clojure.main") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        main_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = main_ns;

    _ = try evalString(allocator, env, main_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/core/server.clj (stub namespace).
pub fn loadCoreServer(allocator: Allocator, env: *Env) BootstrapError!void {
    const server_ns = env.findOrCreateNamespace("clojure.core.server") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        server_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = server_ns;

    _ = try evalString(allocator, env, server_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/spec/gen/alpha.clj (stub namespace).
pub fn loadSpecGenAlpha(allocator: Allocator, env: *Env) BootstrapError!void {
    const spec_gen_ns = env.findOrCreateNamespace("clojure.spec.gen.alpha") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        spec_gen_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = spec_gen_ns;

    _ = try evalString(allocator, env, spec_gen_alpha_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/spec/alpha.clj (spec.alpha core).
/// Must be called after loadSpecGenAlpha (spec.alpha requires spec.gen.alpha).
pub fn loadSpecAlpha(allocator: Allocator, env: *Env) BootstrapError!void {
    const spec_ns = env.findOrCreateNamespace("clojure.spec.alpha") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        spec_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    // Pre-create aliases needed at read time: CW reads all forms before evaluating,
    // so (alias 'c 'clojure.core) in the source hasn't executed when syntax-quotes
    // are processed by the reader. JVM Clojure reads one form at a time.
    spec_ns.setAlias("c", core_ns) catch {};
    if (env.findNamespace("clojure.walk")) |walk_ns| {
        spec_ns.setAlias("walk", walk_ns) catch {};
    }
    if (env.findNamespace("clojure.spec.gen.alpha")) |gen_ns| {
        spec_ns.setAlias("gen", gen_ns) catch {};
    }
    if (env.findNamespace("clojure.string")) |str_ns| {
        spec_ns.setAlias("str", str_ns) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = spec_ns;

    _ = try evalString(allocator, env, spec_alpha_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load and evaluate clojure/core/specs/alpha.clj (core.specs.alpha).
pub fn loadCoreSpecsAlpha(allocator: Allocator, env: *Env) BootstrapError!void {
    const ns = env.findOrCreateNamespace("clojure.core.specs.alpha") catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const saved_ns = env.current_ns;
    env.current_ns = ns;

    _ = try evalString(allocator, env, core_specs_alpha_clj_source);

    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Load an embedded library lazily (called from ns_ops.requireLib on first require).
/// Returns true if the namespace was loaded from embedded source.
pub fn loadEmbeddedLib(allocator: Allocator, env: *Env, ns_name: []const u8) BootstrapError!bool {
    if (std.mem.eql(u8, ns_name, "clojure.uuid")) {
        // clojure.uuid namespace — no vars needed (uuid printing handled in Zig)
        _ = env.findOrCreateNamespace("clojure.uuid") catch return error.EvalError;
        return true;
    }
    if (std.mem.eql(u8, ns_name, "clojure.test.tap")) {
        try loadTestTap(allocator, env);
        return true;
    }
    // clojure.java.browse — registered in registerBuiltins() (Phase B.2)
    // clojure.datafy — registered in registerBuiltins() (Phase B.3)
    // clojure.core.protocols — registered in registerBuiltins() (Phase B.3)
    if (std.mem.eql(u8, ns_name, "clojure.instant")) {
        try loadInstant(allocator, env);
        return true;
    }
    if (std.mem.eql(u8, ns_name, "clojure.xml")) {
        try loadXml(allocator, env);
        return true;
    }
    if (std.mem.eql(u8, ns_name, "clojure.java.process")) {
        // clojure.java.shell is registered in registerBuiltins() (Phase B.2)
        try loadProcess(allocator, env);
        return true;
    }
    if (std.mem.eql(u8, ns_name, "clojure.main")) {
        try loadMain(allocator, env);
        return true;
    }
    if (std.mem.eql(u8, ns_name, "clojure.core.server")) {
        // Ensure dependencies are loaded
        if (env.findNamespace("clojure.main") == null) {
            try loadMain(allocator, env);
        }
        try loadCoreServer(allocator, env);
        return true;
    }
    // clojure.repl.deps — registered in registerBuiltins() (Phase B.3)
    if (std.mem.eql(u8, ns_name, "clojure.spec.gen.alpha")) {
        try loadSpecGenAlpha(allocator, env);
        return true;
    }
    if (std.mem.eql(u8, ns_name, "clojure.spec.alpha")) {
        // Ensure spec.gen.alpha is loaded first (spec.alpha depends on it)
        if (env.findNamespace("clojure.spec.gen.alpha") == null) {
            try loadSpecGenAlpha(allocator, env);
        }
        try loadSpecAlpha(allocator, env);
        return true;
    }
    if (std.mem.eql(u8, ns_name, "clojure.core.specs.alpha")) {
        try loadCoreSpecsAlpha(allocator, env);
        return true;
    }
    return false;
}

/// Sync *ns* var with env.current_ns. Called after manual namespace switches.
pub fn syncNsVar(env: *Env) void {
    const ns_name = if (env.current_ns) |ns| ns.name else "user";
    if (env.findNamespace("clojure.core")) |core| {
        if (core.resolve("*ns*")) |ns_var| {
            const old_val = ns_var.getRawRoot();
            const new_val = Value.initSymbol(env.allocator, .{ .ns = null, .name = ns_name });
            ns_var.bindRoot(new_val);
            env.replaceOwnedSymbol(old_val, new_val);
        }
    }
}

/// Parse source into top-level forms.
/// When current_ns is provided, syntax-quote resolves symbols using that namespace.
fn readForms(allocator: Allocator, source: []const u8) BootstrapError![]Form {
    return readFormsWithNs(allocator, source, null);
}

fn readFormsWithNs(allocator: Allocator, source: []const u8, current_ns: ?*const Namespace) BootstrapError![]Form {
    var reader = Reader.init(allocator, source);
    reader.current_ns = current_ns;
    return reader.readAll() catch return error.ReadError;
}

/// Save and set macro expansion / lazy-seq realization / fn_val dispatch globals.
/// Returns previous state for restoration via defer.
pub const MacroEnvState = struct {
    env: ?*Env,
    pred_env: ?*Env,
};

pub fn setupMacroEnv(env: *Env) MacroEnvState {
    const prev = MacroEnvState{
        .env = macro_eval_env,
        .pred_env = predicates_mod.current_env,
    };
    macro_eval_env = env;
    predicates_mod.current_env = env;
    return prev;
}

pub fn restoreMacroEnv(prev: MacroEnvState) void {
    macro_eval_env = prev.env;
    predicates_mod.current_env = prev.pred_env;
}

/// Analyze a single form with macro expansion support.
fn analyzeForm(allocator: Allocator, env: *Env, form: Form) BootstrapError!*Node {
    var analyzer = Analyzer.initWithEnv(allocator, env);
    defer analyzer.deinit();
    return analyzer.analyze(form) catch return error.AnalyzeError;
}

/// Evaluate a source string in the given Env.
/// Callback invoked after each top-level form is evaluated.
/// Used by -e mode and REPL to print results interleaved with side-effects.
pub const FormObserver = struct {
    context: *anyopaque,
    onResult: *const fn (*anyopaque, Value) void,
};

/// Reads, analyzes, and evaluates each top-level form sequentially.
/// Returns the value of the last form, or nil if source is empty.
pub fn evalString(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    return evalStringInner(allocator, env, source, null);
}

/// Like evalString but calls observer.onResult after each form is evaluated.
/// This ensures result printing is interleaved with side-effects (println etc).
pub fn evalStringObserved(allocator: Allocator, env: *Env, source: []const u8, observer: FormObserver) BootstrapError!Value {
    return evalStringInner(allocator, env, source, observer);
}

fn evalStringInner(allocator: Allocator, env: *Env, source: []const u8, observer: ?FormObserver) BootstrapError!Value {
    // Reader/analyzer use node_arena (GPA-backed, not GC-tracked) so AST Nodes
    // survive GC sweeps. TreeWalk uses allocator (gc_alloc) for Value creation.
    const node_alloc = env.nodeAllocator();

    // Read forms one at a time, updating reader.current_ns after each eval.
    // This ensures syntax-quote symbol resolution uses the correct namespace
    // after (ns ...) forms set up :refer-clojure :exclude mappings.
    var reader = Reader.init(node_alloc, source);
    reader.current_ns = if (env.current_ns) |ns| ns else null;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    // Note: tw is intentionally not deinit'd — closures created during
    // evaluation may be def'd into Vars and must outlive this scope.
    var tw = TreeWalk.initWithEnv(allocator, env);

    var last_value: Value = Value.nil_val;
    while (true) {
        const form = reader.read() catch return error.ReadError;
        if (form == null) break;
        const node = try analyzeForm(node_alloc, env, form.?);
        last_value = tw.run(node) catch {
            err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
            return error.EvalError;
        };
        if (observer) |obs| obs.onResult(obs.context, last_value);
        // Update reader namespace after eval so subsequent syntax-quote
        // resolves symbols in the new namespace (e.g. after ns form).
        reader.current_ns = if (env.current_ns) |ns| ns else null;
    }
    return last_value;
}

/// Evaluate source via Compiler + VM pipeline.
/// Macros are still expanded via TreeWalk (callFnVal), but evaluation
/// uses the bytecode compiler and VM. Cross-backend dispatch (VM<->TW)
/// is handled by callFnVal which both backends import directly.
/// Compile source to bytecode and dump to stderr without executing.
/// Dumps top-level chunks and all nested FnProtos.
pub fn dumpBytecodeVM(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!void {
    const node_alloc = env.nodeAllocator();
    const ns_ptr: ?*const Namespace = if (env.current_ns) |ns| ns else null;
    const forms = try readFormsWithNs(node_alloc, source, ns_ptr);
    if (forms.len == 0) return;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var w = &aw.writer;

    for (forms, 0..) |form, form_idx| {
        const node = try analyzeForm(node_alloc, env, form);

        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        if (env.current_ns) |ns| {
            compiler.current_ns_name = ns.name;
            compiler.current_ns = ns;
        }
        compiler.compile(node) catch return error.CompileError;
        compiler.chunk.emitOp(.ret) catch return error.CompileError;

        w.print("\n=== Form {d} ===\n", .{form_idx}) catch {};
        compiler.chunk.dump(w) catch {};

        // Dump all nested FnProtos
        for (compiler.fn_protos.items) |proto| {
            proto.dump(w) catch {};
        }
    }

    // Write collected output to stderr
    const output = w.buffered();
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    _ = stderr.write(output) catch {};
}

pub fn evalStringVM(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    return evalStringVMInner(allocator, env, source, null);
}

/// Like evalStringVM but calls observer.onResult after each form is evaluated.
pub fn evalStringVMObserved(allocator: Allocator, env: *Env, source: []const u8, observer: FormObserver) BootstrapError!Value {
    return evalStringVMInner(allocator, env, source, observer);
}

fn evalStringVMInner(allocator: Allocator, env: *Env, source: []const u8, observer: ?FormObserver) BootstrapError!Value {
    // Reader/analyzer use node_arena (GPA-backed, not GC-tracked).
    // Compiler/VM use allocator (gc_alloc) for bytecode and Values.
    const node_alloc = env.nodeAllocator();

    // Read forms one at a time, updating reader.current_ns after each eval.
    // This ensures syntax-quote symbol resolution uses the correct namespace
    // after (ns ...) forms set up :refer-clojure :exclude mappings.
    var reader = Reader.init(node_alloc, source);
    reader.current_ns = if (env.current_ns) |ns| ns else null;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    const gc: ?*gc_mod.MarkSweepGc = if (env.gc) |g| @ptrCast(@alignCast(g)) else null;

    if (gc != null) {
        // GC mode: GC owns all allocations. No manual retain/detach needed.
        // Don't call compiler.deinit() — GC traces FnProto internals via traceValue.
        // Heap-allocate VM to avoid C stack overflow (VM struct is ~1.5MB).
        const vm = env.allocator.create(VM) catch return error.CompileError;
        defer env.allocator.destroy(vm);
        var last_value: Value = Value.nil_val;
        while (true) {
            const form = reader.read() catch return error.ReadError;
            if (form == null) break;
            const node = try analyzeForm(node_alloc, env, form.?);

            var compiler = Compiler.init(allocator);
            if (env.current_ns) |ns| {
                compiler.current_ns_name = ns.name;
                compiler.current_ns = ns;
            }
            compiler.compile(node) catch return error.CompileError;
            compiler.chunk.emitOp(.ret) catch return error.CompileError;

            vm.* = VM.initWithEnv(allocator, env);
            vm.gc = gc;
            last_value = vm.run(&compiler.chunk) catch {
                err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
                return error.EvalError;
            };
            if (observer) |obs| obs.onResult(obs.context, last_value);
            reader.current_ns = if (env.current_ns) |ns| ns else null;
        }
        return last_value;
    }

    // Non-GC mode: manual retain/detach pattern (fix for use-after-free T9.5.1).
    var retained_protos: std.ArrayList(*const chunk_mod.FnProto) = .empty;
    defer {
        for (retained_protos.items) |proto| {
            allocator.free(proto.code);
            allocator.free(proto.constants);
            allocator.destroy(@constCast(proto));
        }
        retained_protos.deinit(allocator);
    }
    var retained_fns: std.ArrayList(*const value_mod.Fn) = .empty;
    defer {
        for (retained_fns.items) |fn_obj| {
            allocator.destroy(@constCast(fn_obj));
        }
        retained_fns.deinit(allocator);
    }

    var last_value: Value = Value.nil_val;
    while (true) {
        const form = reader.read() catch return error.ReadError;
        if (form == null) break;
        const node = try analyzeForm(node_alloc, env, form.?);

        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        if (env.current_ns) |ns| {
            compiler.current_ns_name = ns.name;
            compiler.current_ns = ns;
        }
        compiler.compile(node) catch return error.CompileError;
        compiler.chunk.emitOp(.ret) catch return error.CompileError;

        const detached = compiler.detachFnAllocations();
        for (detached.fn_protos) |p| {
            retained_protos.append(allocator, p) catch return error.CompileError;
        }
        if (detached.fn_protos.len > 0) allocator.free(detached.fn_protos);
        for (detached.fn_objects) |o| {
            retained_fns.append(allocator, o) catch return error.CompileError;
        }
        if (detached.fn_objects.len > 0) allocator.free(detached.fn_objects);

        // Heap-allocate VM to avoid C stack overflow (VM struct is ~1.5MB).
        const vm = env.allocator.create(VM) catch return error.CompileError;
        vm.* = VM.initWithEnv(allocator, env);
        defer {
            vm.deinit();
            env.allocator.destroy(vm);
        }
        last_value = vm.run(&compiler.chunk) catch {
            err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
            return error.EvalError;
        };
        if (observer) |obs| obs.onResult(obs.context, last_value);

        const vm_fns = vm.detachFnAllocations();
        for (vm_fns) |f| {
            retained_fns.append(allocator, f) catch return error.CompileError;
        }
        if (vm_fns.len > 0) allocator.free(vm_fns);
        reader.current_ns = if (env.current_ns) |ns| ns else null;
    }
    return last_value;
}

/// Evaluate source via Compiler+VM, retaining all FnProto/Fn allocations.
/// Used for bootstrap where closures are stored in Vars and must outlive evaluation.
/// Compiler is intentionally NOT deinit'd — FnProtos referenced by Fn objects in Vars
/// must persist for the program lifetime. The VM is also not deinit'd — allocated
/// Values (lists, vectors, maps, fns) may be stored in Vars via def/defn.
fn evalStringVMBootstrap(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    const node_alloc = env.nodeAllocator();

    // Read forms one at a time, updating reader.current_ns after each eval.
    var reader = Reader.init(node_alloc, source);
    reader.current_ns = if (env.current_ns) |ns| ns else null;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    // Heap-allocate VM to avoid C stack overflow (VM struct is ~1.5MB).
    // Reused across forms — re-initialized each iteration.
    const vm = env.allocator.create(VM) catch return error.CompileError;
    defer env.allocator.destroy(vm);

    var last_value: Value = Value.nil_val;
    while (true) {
        const form = reader.read() catch return error.ReadError;
        if (form == null) break;
        const node = try analyzeForm(node_alloc, env, form.?);

        // Note: compiler is intentionally NOT deinit'd — closures created during
        // evaluation may be def'd into Vars and must outlive this scope.
        var compiler = Compiler.init(allocator);
        if (env.current_ns) |ns| {
            compiler.current_ns_name = ns.name;
            compiler.current_ns = ns;
        }
        compiler.compile(node) catch return error.CompileError;
        compiler.chunk.emitOp(.ret) catch return error.CompileError;

        vm.* = VM.initWithEnv(allocator, env);
        last_value = vm.run(&compiler.chunk) catch {
            err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
            return error.EvalError;
        };
        reader.current_ns = if (env.current_ns) |ns| ns else null;
    }
    return last_value;
}

/// Unified fn_val dispatch — single entry point for calling any callable Value.
///
/// Routes by Fn.kind: treewalk closures go to TreeWalk, bytecode closures
/// go to a VM instance, builtin_fn is called directly. Also handles
/// multimethods, keywords-as-functions, maps/sets-as-functions, var derefs,
/// and protocol dispatch.
///
/// This replaces 5 separate dispatch mechanisms (D36/T10.4):
///   vm.zig, tree_walk.zig, atom.zig, value.zig, analyzer.zig
/// all import bootstrap.callFnVal directly (no more callback wiring, ~180 lines saved).
///
/// Active VM bridge: When a bytecode closure is called and an active
/// VM exists (set via vm.zig's execute()), we reuse that VM's stack via
/// callFunction() instead of creating a new VM instance (~500KB heap alloc).
/// This is the critical path for fused reduce callbacks and makes deep
/// predicate chains (sieve's 168 filters) feasible.
pub fn callFnVal(allocator: Allocator, fn_val: Value, args: []const Value) anyerror!Value {
    switch (fn_val.tag()) {
        .builtin_fn => return fn_val.asBuiltinFn()(allocator, args),
        .fn_val => {
            const fn_obj = fn_val.asFn();
            if (fn_obj.kind == .bytecode) {
                // Active VM bridge: reuse existing VM stack (avoids ~500KB heap alloc)
                if (vm_mod.active_vm) |vm| {
                    return vm.callFunction(fn_val, args) catch |e| {
                        return @as(anyerror, @errorCast(e));
                    };
                }
                return bytecodeCallBridge(allocator, fn_val, args);
            } else {
                return treewalkCallBridge(allocator, fn_val, args);
            }
        },
        .multi_fn => {
            const mf = fn_val.asMultiFn();
            // Dispatch: call dispatch_fn, lookup method, call method
            const dispatch_val = try callFnVal(allocator, mf.dispatch_fn, args);
            const method_fn = mf.methods.get(dispatch_val) orelse
                mf.methods.get(Value.initKeyword(allocator, .{ .ns = null, .name = "default" })) orelse
                return error.TypeError;
            return callFnVal(allocator, method_fn, args);
        },
        .keyword => {
            const kw = fn_val.asKeyword();
            // Keyword-as-function: (:key map) => (get map :key)
            if (args.len < 1) return error.TypeError;
            if (args[0].tag() == .wasm_module and args.len == 1) {
                const wm = args[0].asWasmModule();
                return if (wm.getExportFn(kw.name)) |wf|
                    Value.initWasmFn(wf)
                else
                    Value.nil_val;
            }
            if (args[0].tag() == .map) {
                return args[0].asMap().get(fn_val) orelse
                    if (args.len >= 2) args[1] else Value.nil_val;
            }
            return if (args.len >= 2) args[1] else Value.nil_val;
        },
        .map => {
            const m = fn_val.asMap();
            // Map-as-function: ({:a 1} :b) => (get map key)
            if (args.len < 1) return error.TypeError;
            return m.get(args[0]) orelse
                if (args.len >= 2) args[1] else Value.nil_val;
        },
        .set => {
            const s = fn_val.asSet();
            // Set-as-function: (#{:a :b} :a) => :a or nil
            if (args.len < 1) return error.TypeError;
            return if (s.contains(args[0])) args[0] else Value.nil_val;
        },
        .wasm_module => {
            const wm = fn_val.asWasmModule();
            // Module-as-function: (mod :add) => cached WasmFn
            if (args.len != 1) return error.ArityError;
            const name = switch (args[0].tag()) {
                .keyword => args[0].asKeyword().name,
                .string => args[0].asString(),
                else => return error.TypeError,
            };
            return if (wm.getExportFn(name)) |wf|
                Value.initWasmFn(wf)
            else
                Value.nil_val;
        },
        .wasm_fn => return fn_val.asWasmFn().call(allocator, args),
        .var_ref => return callFnVal(allocator, fn_val.asVarRef().deref(), args),
        .protocol_fn => {
            const pf = fn_val.asProtocolFn();
            if (args.len == 0) return error.ArityError;
            const type_key = TreeWalk.valueTypeKey(args[0]);
            const method_map_val = pf.protocol.impls.getByStringKey(type_key) orelse return error.TypeError;
            if (method_map_val.tag() != .map) return error.TypeError;
            const impl_fn = method_map_val.asMap().getByStringKey(pf.method_name) orelse return error.TypeError;
            return callFnVal(allocator, impl_fn, args);
        },
        else => return error.TypeError,
    }
}

/// Execute a treewalk fn_val via TreeWalk evaluator.
fn treewalkCallBridge(allocator: Allocator, fn_val: Value, args: []const Value) anyerror!Value {
    // Note: tw is NOT deinit'd here — closures created during evaluation
    // (e.g., lazy-seq thunks) must outlive this scope. Memory is owned by
    // the arena allocator, which handles bulk deallocation.
    var tw = if (macro_eval_env) |env|
        TreeWalk.initWithEnv(allocator, env)
    else
        TreeWalk.init(allocator);
    return tw.callValue(fn_val, args) catch |e| {
        // Preserve exception value across TreeWalk → VM boundary
        if (e == error.UserException) {
            last_thrown_exception = tw.exception;
        }
        return @as(anyerror, e);
    };
}

/// Last exception value thrown by TreeWalk, for VM boundary crossing.
/// VM reads this in dispatchErrorToHandler to avoid creating generic ExInfo.
/// Per-thread for concurrency (Phase 48).
pub threadlocal var last_thrown_exception: ?Value = null;

/// Flag set by apply's lazy variadic path (F99). When true, the single rest arg
/// in the next variadic call is already a seq and should not be re-wrapped in a list.
/// Consumed (reset to false) by VM/TreeWalk rest packing code.
pub threadlocal var apply_rest_is_seq: bool = false;

/// Execute a bytecode fn_val via a new VM instance.
/// Heap-allocates the VM to avoid C stack overflow from recursive
/// VM → TreeWalk → VM calls (VM struct is ~500KB due to fixed-size stack).
fn bytecodeCallBridge(allocator: Allocator, fn_val: Value, args: []const Value) anyerror!Value {
    const env = macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    // Save namespace before VM call — performCall switches to the function's
    // defining namespace (D68), but if the function throws, the ret opcode
    // never executes and the namespace stays corrupted.
    const saved_ns = env.current_ns;
    errdefer env.current_ns = saved_ns;
    // Note: VM is NOT deinit'd here — closures created during execution
    // (e.g., fn values returned from calls) must outlive this scope.
    // Memory is owned by the arena allocator, which handles bulk deallocation.
    const vm = try allocator.create(VM);
    vm.* = VM.initWithEnv(allocator, env);

    // Push fn_val onto stack
    try vm.push(fn_val);
    // Push args
    for (args) |arg| {
        try vm.push(arg);
    }
    // Call the function
    try vm.performCall(@intCast(args.len));
    // Execute until return
    return vm.execute();
}

/// Env reference for macro expansion bridge. Set during evalString.
/// Public so eval builtins (eval.zig) can access the current Env.
/// Per-thread for concurrency (Phase 48).
pub threadlocal var macro_eval_env: ?*Env = null;

// === AOT Compilation ===

const serialize_mod = @import("../compiler/serialize.zig");

/// Compile source to a serialized bytecode Module.
///
/// Parses, analyzes (with macro expansion), and compiles all top-level forms
/// into a single Chunk. The resulting Module (header + string table + FnProto
/// table + Chunk) is returned as owned bytes.
///
/// Requires bootstrap already loaded (macros must be available for expansion).
pub fn compileToModule(allocator: Allocator, env: *Env, source: []const u8) BootstrapError![]const u8 {
    const node_alloc = env.nodeAllocator();
    const forms = try readForms(node_alloc, source);
    if (forms.len == 0) return error.CompileError;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    // Compile all forms into a single Chunk.
    // Intermediate form results are popped; final form result is returned by .ret.
    var compiler = Compiler.init(allocator);
    if (env.current_ns) |ns| {
        compiler.current_ns_name = ns.name;
        compiler.current_ns = ns;
    }
    for (forms, 0..) |form, i| {
        const node = try analyzeForm(node_alloc, env, form);
        compiler.compile(node) catch return error.CompileError;
        if (i < forms.len - 1) {
            compiler.chunk.emitOp(.pop) catch return error.CompileError;
        }
    }
    compiler.chunk.emitOp(.ret) catch return error.CompileError;

    // Serialize the Module
    var ser: serialize_mod.Serializer = .{};
    ser.serializeModule(allocator, &compiler.chunk) catch return error.CompileError;
    const bytes = ser.getBytes();
    return allocator.dupe(u8, bytes) catch return error.OutOfMemory;
}

/// Run a compiled bytecode Module in the given Env.
///
/// Deserializes the Module, then runs the top-level Chunk via VM.
/// Returns the value of the last form.
pub fn runBytecodeModule(allocator: Allocator, env: *Env, module_bytes: []const u8) BootstrapError!Value {
    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    var de: serialize_mod.Deserializer = .{ .data = module_bytes };
    const chunk = de.deserializeModule(allocator) catch return error.CompileError;

    const gc: ?*gc_mod.MarkSweepGc = if (env.gc) |g| @ptrCast(@alignCast(g)) else null;

    // Heap-allocate VM (struct is ~1.5MB)
    const vm = env.allocator.create(VM) catch return error.CompileError;
    defer env.allocator.destroy(vm);
    vm.* = VM.initWithEnv(allocator, env);
    vm.gc = gc;
    return vm.run(&chunk) catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };
}

/// Unified bootstrap: loads all standard library namespaces.
///
/// Equivalent to the sequence: loadCore + loadWalk + loadTest + loadSet + loadData.
/// Use this instead of calling each individually.
pub fn loadBootstrapAll(allocator: Allocator, env: *Env) BootstrapError!void {
    try loadCore(allocator, env);
    try loadWalk(allocator, env);
    try loadTest(allocator, env);
    try loadSet(allocator, env);
    try loadData(allocator, env);
    try loadRepl(allocator, env);
    try loadJavaIo(allocator, env);
    try loadPprint(allocator, env);
    try loadStacktrace(allocator, env);
    try loadZip(allocator, env);
    // clojure.core.protocols — registered in registerBuiltins() (Phase B.3)
    try loadReducers(allocator, env);
    // spec.alpha loaded lazily on first require (startup time)
}

/// Re-compile all bootstrap functions to bytecode via VM compiler.
///
/// After normal TreeWalk bootstrap, vars hold TreeWalk closures (kind=treewalk).
/// These cannot be serialized because their proto points to TreeWalk.Closure (AST),
/// not FnProto (bytecode). This function re-evaluates all bootstrap source files
/// through the VM compiler, replacing all defn/defmacro var roots with bytecode closures.
///
/// Must be called after loadBootstrapAll(). After this, all top-level fn_val vars
/// are bytecode-backed and eligible for serialization.
pub fn vmRecompileAll(allocator: Allocator, env: *Env) BootstrapError!void {
    const saved_ns = env.current_ns;

    // Re-compile core.clj (all defn/defmacro forms → bytecode)
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    env.current_ns = core_ns;
    _ = try evalStringVMBootstrap(allocator, env, core_clj_source);
    _ = try evalStringVMBootstrap(allocator, env, hot_core_defs);
    _ = try evalStringVMBootstrap(allocator, env, core_hof_defs);
    _ = try evalStringVMBootstrap(allocator, env, core_seq_defs);

    // Re-compile walk.clj
    if (env.findNamespace("clojure.walk")) |walk_ns| {
        env.current_ns = walk_ns;
        _ = try evalStringVMBootstrap(allocator, env, walk_clj_source);
    }


    // Re-compile test.clj
    if (env.findNamespace("clojure.test")) |test_ns| {
        env.current_ns = test_ns;
        _ = try evalStringVMBootstrap(allocator, env, test_clj_source);
    }

    // Re-compile set.clj
    if (env.findNamespace("clojure.set")) |set_ns| {
        env.current_ns = set_ns;
        _ = try evalStringVMBootstrap(allocator, env, set_clj_source);
    }

    // Re-compile data.clj
    if (env.findNamespace("clojure.data")) |data_ns| {
        env.current_ns = data_ns;
        _ = try evalStringVMBootstrap(allocator, env, data_clj_source);
    }

    // Re-compile repl.clj
    if (env.findNamespace("clojure.repl")) |repl_ns| {
        env.current_ns = repl_ns;
        _ = try evalStringVMBootstrap(allocator, env, repl_clj_source);
    }

    // Re-compile java/io.clj
    if (env.findNamespace("clojure.java.io")) |io_ns| {
        env.current_ns = io_ns;
        _ = try evalStringVMBootstrap(allocator, env, io_clj_source);
    }

    // Re-compile pprint.clj
    if (env.findNamespace("clojure.pprint")) |pprint_ns| {
        env.current_ns = pprint_ns;
        _ = try evalStringVMBootstrap(allocator, env, pprint_clj_source);
    }

    // Re-compile stacktrace.clj
    if (env.findNamespace("clojure.stacktrace")) |st_ns| {
        env.current_ns = st_ns;
        _ = try evalStringVMBootstrap(allocator, env, stacktrace_clj_source);
    }

    // Re-compile zip.clj
    if (env.findNamespace("clojure.zip")) |zip_ns| {
        env.current_ns = zip_ns;
        _ = try evalStringVMBootstrap(allocator, env, zip_clj_source);
    }

    // clojure.core.protocols — Zig builtins (Phase B.3), no recompilation needed

    // Re-compile core/reducers.clj
    if (env.findNamespace("clojure.core.reducers")) |reducers_ns| {
        env.current_ns = reducers_ns;
        _ = try evalStringVMBootstrap(allocator, env, reducers_clj_source);
    }

    // spec.alpha re-compiled lazily on first require (startup time)

    // Restore namespace
    env.current_ns = saved_ns;
    syncNsVar(env);
}

/// Generate a bootstrap cache: serialized env state with all fns as bytecode.
///
/// Performs full bootstrap (TreeWalk), re-compiles all fns to bytecode,
/// then serializes the entire env state. Returns owned bytes that can
/// be written to a cache file or embedded in a binary.
pub fn generateBootstrapCache(allocator: Allocator, env: *Env) BootstrapError![]const u8 {
    // Re-compile all bootstrap fns to bytecode (required for serialization)
    try vmRecompileAll(allocator, env);

    // Serialize env snapshot
    var ser: serialize_mod.Serializer = .{};
    ser.serializeEnvSnapshot(allocator, env) catch return error.CompileError;
    // Return a copy of the serialized bytes owned by the caller's allocator
    const bytes = ser.getBytes();
    return allocator.dupe(u8, bytes) catch return error.OutOfMemory;
}

/// Restore bootstrap state from a cache (serialized env snapshot).
///
/// Expects registerBuiltins(env) already called. Restores all namespaces,
/// vars, refers, and aliases from the cache bytes. Reconnects *print-length*
/// and *print-level* var caches for correct print behavior.
pub fn restoreFromBootstrapCache(allocator: Allocator, env: *Env, cache_bytes: []const u8) BootstrapError!void {
    var de: serialize_mod.Deserializer = .{ .data = cache_bytes };
    de.restoreEnvSnapshotLazy(allocator, env) catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    // Reconnect printVar caches (value.initPrintVars)
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    if (core_ns.resolve("*print-length*")) |pl_var| {
        if (core_ns.resolve("*print-level*")) |pv_var| {
            value_mod.initPrintVars(pl_var, pv_var);
        }
    }
    if (core_ns.resolve("*print-readably*")) |pr_var| {
        if (core_ns.resolve("*print-meta*")) |pm_var| {
            value_mod.initPrintFlagVars(pr_var, pm_var);
        }
    }

    // Cache *print-dup* var for readable override
    if (core_ns.resolve("*print-dup*")) |pd_var| {
        value_mod.initPrintDupVar(pd_var);
    }

    // Cache *agent* var for binding in agent action processing
    if (core_ns.resolve("*agent*")) |agent_v| {
        const thread_pool_mod = @import("thread_pool.zig");
        thread_pool_mod.initAgentVar(agent_v);
    }

    // Ensure *ns* is synced
    syncNsVar(env);
}

// === Tests ===

const testing = std.testing;
const registry = @import("../builtins/registry.zig");

/// Test helper: evaluate expression and check integer result.
fn expectEvalInt(alloc: std.mem.Allocator, env: *Env, source: []const u8, expected: i64) !void {
    const result = try evalString(alloc, env, source);
    try testing.expectEqual(Value.initInteger(expected), result);
}

/// Test helper: evaluate expression and check boolean result.
fn expectEvalBool(alloc: std.mem.Allocator, env: *Env, source: []const u8, expected: bool) !void {
    const result = try evalString(alloc, env, source);
    try testing.expectEqual(Value.initBoolean(expected), result);
}

/// Test helper: evaluate expression and check nil result.
fn expectEvalNil(alloc: std.mem.Allocator, env: *Env, source: []const u8) !void {
    const result = try evalString(alloc, env, source);
    try testing.expectEqual(Value.nil_val, result);
}

/// Test helper: evaluate expression and check string result.
fn expectEvalStr(alloc: std.mem.Allocator, env: *Env, source: []const u8, expected: []const u8) !void {
    const result = try evalString(alloc, env, source);
    try testing.expectEqualStrings(expected, result.asString());
}

test "evalString - simple constant" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    const result = try evalString(alloc, &env, "42");
    try testing.expectEqual(Value.initInteger(42), result);
}

test "evalString - function call" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    const result = try evalString(alloc, &env, "(+ 1 2)");
    try testing.expectEqual(Value.initInteger(3), result);
}

test "evalString - multiple forms returns last" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    const result = try evalString(alloc, &env, "1 2 3");
    try testing.expectEqual(Value.initInteger(3), result);
}

test "evalString - def + reference" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    const result = try evalString(alloc, &env, "(def x 10) (+ x 5)");
    try testing.expectEqual(Value.initInteger(15), result);
}

test "evalString - defmacro and macro use" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Define a macro: (defmacro my-const [x] x)
    // This macro just returns its argument unevaluated (identity macro)
    // Then use it: (my-const 42) -> 42
    const result = try evalString(alloc, &env,
        \\(defmacro my-const [x] x)
        \\(my-const 42)
    );
    try testing.expectEqual(Value.initInteger(42), result);
}

test "evalString - defn macro from core" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Step 1: define defn macro
    const r1 = try evalString(alloc, &env,
        \\(defmacro defn [name & fdecl]
        \\  `(def ~name (fn ~name ~@fdecl)))
    );
    _ = r1;

    // Step 2: use defn macro
    const r2 = try evalString(alloc, &env,
        \\(defn add1 [x] (+ x 1))
    );
    _ = r2;

    // Step 3: call defined function
    const result = try evalString(alloc, &env,
        \\(add1 10)
    );
    try testing.expectEqual(Value.initInteger(11), result);
}

test "evalString - when macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Define when macro
    _ = try evalString(alloc, &env,
        \\(defmacro when [test & body]
        \\  `(if ~test (do ~@body)))
    );

    // when true -> returns body result
    const r1 = try evalString(alloc, &env, "(when true 42)");
    try testing.expectEqual(Value.initInteger(42), r1);

    // when false -> returns nil
    const r2 = try evalString(alloc, &env, "(when false 42)");
    try testing.expectEqual(Value.nil_val, r2);
}

test "loadCore - core.clj defines defn and when" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Load core.clj
    try loadCore(alloc, &env);

    // defn is now a Zig macro transform (not a defmacro var)
    // Verify it works via the Zig transform pipeline
    const defn_result = try evalString(alloc, &env, "(defn my-inc [x] (+ x 1)) (my-inc 5)");
    try testing.expectEqual(Value.initInteger(6), defn_result);

    // when is now a Zig macro transform (not a defmacro var)
    // Verify it works via the Zig transform pipeline
    const when_result = try evalString(alloc, &env, "(when true 42)");
    try testing.expectEqual(Value.initInteger(42), when_result);
    const when_nil = try evalString(alloc, &env, "(when false 42)");
    try testing.expectEqual(Value.nil_val, when_nil);

    // Use defn from core.clj
    const result = try evalString(alloc, &env,
        \\(defn double [x] (+ x x))
        \\(double 21)
    );
    try testing.expectEqual(Value.initInteger(42), result);
}

test "evalString - higher-order function call" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Pass fn as argument and call it
    const result = try evalString(alloc, &env,
        \\(defn apply1 [f x] (f x))
        \\(defn inc [x] (+ x 1))
        \\(apply1 inc 41)
    );
    try testing.expectEqual(Value.initInteger(42), result);
}

test "evalString - loop/recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Sum 1..10 using loop/recur
    const result = try evalString(alloc, &env,
        \\(loop [i 0 sum 0]
        \\  (if (= i 10)
        \\    sum
        \\    (recur (+ i 1) (+ sum i))))
    );
    try testing.expectEqual(Value.initInteger(45), result);
}

test "core.clj - next returns nil for empty" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // next of single-element list should be nil
    const r1 = try evalString(alloc, &env, "(next (list 1))");
    try testing.expectEqual(Value.nil_val, r1);

    // next of multi-element list should be non-nil
    const r2 = try evalString(alloc, &env, "(next (list 1 2))");
    try testing.expect(r2.tag() == .list);
}

test "core.clj - map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn inc [x] (+ x 1))");
    const raw_result = try evalString(alloc, &env, "(map inc (list 1 2 3))");
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw_result);
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try testing.expectEqual(Value.initInteger(2), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(3), result.asList().items[1]);
    try testing.expectEqual(Value.initInteger(4), result.asList().items[2]);
}

test "core.clj - filter" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn even? [x] (= 0 (rem x 2)))");
    const raw_result = try evalString(alloc, &env, "(filter even? (list 1 2 3 4 5 6))");
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw_result);
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try testing.expectEqual(Value.initInteger(2), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(4), result.asList().items[1]);
    try testing.expectEqual(Value.initInteger(6), result.asList().items[2]);
}

test "core.clj - reduce" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // reduce using core.clj definition
    _ = try evalString(alloc, &env, "(defn add [a b] (+ a b))");
    const result = try evalString(alloc, &env, "(reduce add 0 (list 1 2 3))");
    try testing.expectEqual(Value.initInteger(6), result);
}

test "core.clj - take" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const raw_result = try evalString(alloc, &env, "(take 2 (list 1 2 3 4 5))");
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw_result);
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 2), result.asList().items.len);
    try testing.expectEqual(Value.initInteger(1), result.asList().items[0]);
    try testing.expectEqual(Value.initInteger(2), result.asList().items[1]);
}

test "core.clj - drop" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(vec (drop 2 (list 1 2 3 4 5)))");
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try testing.expectEqual(Value.initInteger(3), result.asVector().items[0]);
    try testing.expectEqual(Value.initInteger(4), result.asVector().items[1]);
    try testing.expectEqual(Value.initInteger(5), result.asVector().items[2]);
}

test "core.clj - comment" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(comment 1 2 3)");
    try testing.expectEqual(Value.nil_val, result);
}

test "core.clj - cond" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // First branch true
    const r1 = try evalString(alloc, &env,
        \\(cond
        \\  true 1
        \\  true 2)
    );
    try testing.expectEqual(Value.initInteger(1), r1);

    // Second branch true
    const r2 = try evalString(alloc, &env,
        \\(cond
        \\  false 1
        \\  true 2)
    );
    try testing.expectEqual(Value.initInteger(2), r2);

    // No branch matches -> nil
    const r3 = try evalString(alloc, &env,
        \\(cond
        \\  false 1
        \\  false 2)
    );
    try testing.expectEqual(Value.nil_val, r3);
}

test "core.clj - if-not" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(if-not false 1 2)");
    try testing.expectEqual(Value.initInteger(1), r1);

    const r2 = try evalString(alloc, &env, "(if-not true 1 2)");
    try testing.expectEqual(Value.initInteger(2), r2);
}

test "core.clj - when-not" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(when-not false 42)");
    try testing.expectEqual(Value.initInteger(42), r1);

    const r2 = try evalString(alloc, &env, "(when-not true 42)");
    try testing.expectEqual(Value.nil_val, r2);
}

test "core.clj - and/or" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // and
    const a1 = try evalString(alloc, &env, "(and true true)");
    try testing.expectEqual(Value.true_val, a1);
    const a2 = try evalString(alloc, &env, "(and true false)");
    try testing.expectEqual(Value.false_val, a2);
    const a3 = try evalString(alloc, &env, "(and nil 42)");
    try testing.expectEqual(Value.nil_val, a3);
    const a4 = try evalString(alloc, &env, "(and 1 2 3)");
    try testing.expectEqual(Value.initInteger(3), a4);

    // or
    const o1 = try evalString(alloc, &env, "(or nil false 42)");
    try testing.expectEqual(Value.initInteger(42), o1);
    const o2 = try evalString(alloc, &env, "(or nil false)");
    try testing.expectEqual(Value.false_val, o2);
    const o3 = try evalString(alloc, &env, "(or 1 2)");
    try testing.expectEqual(Value.initInteger(1), o3);
}

test "core.clj - identity/constantly/complement" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(identity 42)");
    try testing.expectEqual(Value.initInteger(42), r1);

    const r2 = try evalString(alloc, &env, "((constantly 99) 1 2 3)");
    try testing.expectEqual(Value.initInteger(99), r2);

    const r3 = try evalString(alloc, &env, "((complement nil?) 42)");
    try testing.expectEqual(Value.true_val, r3);
    const r4 = try evalString(alloc, &env, "((complement nil?) nil)");
    try testing.expectEqual(Value.false_val, r4);
}

test "core.clj - thread-first" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn inc [x] (+ x 1))");
    _ = try evalString(alloc, &env, "(defn double [x] (* x 2))");

    // (-> 5 inc double) => (double (inc 5)) => 12
    const r1 = try evalString(alloc, &env, "(-> 5 inc double)");
    try testing.expectEqual(Value.initInteger(12), r1);
}

test "core.clj - thread-last" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // (->> (list 1 2 3) (map inc)) with inline inc
    _ = try evalString(alloc, &env, "(defn inc [x] (+ x 1))");
    const raw_r1 = try evalString(alloc, &env, "(->> (list 1 2 3) (map inc))");
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const r1 = try builtin_collections.realizeValue(alloc, raw_r1);
    try testing.expect(r1.tag() == .list);
    try testing.expectEqual(@as(usize, 3), r1.asList().items.len);
    try testing.expectEqual(Value.initInteger(2), r1.asList().items[0]);
}

test "core.clj - defn-" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn- private-fn [x] (+ x 10))");
    const result = try evalString(alloc, &env, "(private-fn 5)");
    try testing.expectEqual(Value.initInteger(15), result);
}

test "core.clj - dotimes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // dotimes returns nil (side-effect macro)
    const result = try evalString(alloc, &env, "(dotimes [i 3] i)");
    try testing.expectEqual(Value.nil_val, result);
}

// =========================================================================
// SCI Tier 1 compatibility tests
// Ported from ClojureWasmBeta test/compat/sci/core_test.clj
// =========================================================================

test "SCI - do" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(do 0 1 2)", 2);
    try expectEvalNil(alloc, &env, "(do 1 2 nil)");
}

test "SCI - if and when" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 0] (if (zero? x) 1 2))", 1);
    try expectEvalInt(alloc, &env, "(let [x 1] (if (zero? x) 1 2))", 2);
    try expectEvalInt(alloc, &env, "(let [x 0] (when (zero? x) 1))", 1);
    try expectEvalNil(alloc, &env, "(let [x 1] (when (zero? x) 1))");
    try expectEvalInt(alloc, &env, "(when true 0 1 2)", 2);
}

test "SCI - and / or" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(let [x 0] (and false true x))", false);
    try expectEvalInt(alloc, &env, "(let [x 0] (and true true x))", 0);
    try expectEvalInt(alloc, &env, "(let [x 1] (or false false x))", 1);
    try expectEvalBool(alloc, &env, "(let [x false] (or false false x))", false);
    try expectEvalInt(alloc, &env, "(let [x false] (or false false x 3))", 3);
}

test "SCI - fn named recursion" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "((fn foo [x] (if (< x 3) (foo (inc x)) x)) 0)", 3);
}

test "SCI - def" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(do (def foo "nice val") foo)
    , "nice val");
}

test "SCI - defn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(do (defn my-inc [x] (inc x)) (my-inc 1))", 2);
}

test "SCI - let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 2] 1 2 3 x)", 2);
}

test "SCI - closure" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(do (let [x 1] (defn cl-foo [] x)) (cl-foo))", 1);
    try expectEvalInt(alloc, &env,
        "(let [x 1 y 2] ((fn [] (let [g (fn [] y)] (+ x (g))))))", 3);
}

test "SCI - arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(+ 1 2)", 3);
    try expectEvalInt(alloc, &env, "(+)", 0);
    try expectEvalInt(alloc, &env, "(* 2 3)", 6);
    try expectEvalInt(alloc, &env, "(*)", 1);
    try expectEvalInt(alloc, &env, "(- 1)", -1);
    try expectEvalInt(alloc, &env, "(mod 10 7)", 3);
}

test "SCI - comparisons" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(= 1 1)", true);
    try expectEvalBool(alloc, &env, "(not= 1 2)", true);
    try expectEvalBool(alloc, &env, "(< 1 2)", true);
    try expectEvalBool(alloc, &env, "(< 1 3 2)", false);
    try expectEvalBool(alloc, &env, "(<= 1 1)", true);
    try expectEvalBool(alloc, &env, "(zero? 0)", true);
    try expectEvalBool(alloc, &env, "(pos? 1)", true);
    try expectEvalBool(alloc, &env, "(neg? -1)", true);
}

test "SCI - sequences" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(= (list 2 3 4) (map inc (list 1 2 3)))", true);
    try expectEvalBool(alloc, &env, "(= (list 2 4) (filter even? (list 1 2 3 4 5)))", true);
    try expectEvalInt(alloc, &env, "(reduce + 0 (list 1 2 3 4))", 10);
    try expectEvalInt(alloc, &env, "(reduce + 5 (list 1 2 3 4))", 15);
    try expectEvalInt(alloc, &env, "(first (list 1 2 3))", 1);
    try expectEvalNil(alloc, &env, "(next (list 1))");
    try expectEvalBool(alloc, &env, "(= (list 1 2) (take 2 (list 1 2 3 4)))", true);
}

test "SCI - string operations" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(str "hello" " " "world")
    , "hello world");
    try expectEvalStr(alloc, &env, "(str)", "");
}

test "SCI - loop/recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 1] (loop [x (inc x)] x))", 2);
    try expectEvalInt(alloc, &env, "(loop [x 0] (if (< x 10000) (recur (inc x)) x))", 10000);
    try expectEvalInt(alloc, &env, "((fn foo [x] (if (= 72 x) x (foo (inc x)))) 0)", 72);
}

test "SCI - cond" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 2] (cond (string? x) 1 true 2))", 2);
}

test "SCI - comment" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalNil(alloc, &env, "(comment (+ 1 2 (* 3 4)))");
}

test "SCI - threading macros" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 1] (-> x inc inc (inc)))", 4);
}

test "SCI - quoting" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(= (list 1 2 3) '(1 2 3))", true);
}

test "SCI - defn-" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(do (defn- priv-fn [] 42) (priv-fn))", 42);
}

// === VM eval tests ===

/// Test helper: evaluate expression via VM and check integer result.
fn expectVMEvalInt(alloc: std.mem.Allocator, env: *Env, source: []const u8, expected: i64) !void {
    const result = try evalStringVM(alloc, env, source);
    try testing.expectEqual(Value.initInteger(expected), result);
}

test "evalStringVM - basic arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    try expectVMEvalInt(alloc, &env, "(+ 1 2 3)", 6);
    try expectVMEvalInt(alloc, &env, "(- 10 3)", 7);
    try expectVMEvalInt(alloc, &env, "(* 4 5)", 20);
}

test "evalStringVM - calls core.clj fn (inc)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // inc is defined in core.clj as (defn inc [x] (+ x 1))
    // VM should call the TreeWalk closure via fn_val_dispatcher
    try expectVMEvalInt(alloc, &env, "(inc 5)", 6);
}

test "evalStringVM - uses core macro (when)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // when is a macro — expanded at analyze time, so VM just sees (if ...)
    try expectVMEvalInt(alloc, &env, "(when true 42)", 42);
}

test "evalStringVM - def and call fn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Inline fn call (no def)
    try expectVMEvalInt(alloc, &env, "((fn [x] (* x 2)) 21)", 42);
}

test "evalStringVM - defn and call" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // defn macro expands to (def double (fn double [x] (* x 2)))
    // VM compiles and executes the def, then calls the VM-compiled closure
    try expectVMEvalInt(alloc, &env, "(do (defn double [x] (* x 2)) (double 21))", 42);
}

test "evalStringVM - loop/recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectVMEvalInt(alloc, &env,
        "(loop [x 0] (if (< x 5) (recur (+ x 1)) x))", 5);
}

test "evalStringVM - loop/recur multi-binding (fib)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // (loop [i 0 a 0 b 1] (if (= i 10) a (recur (+ i 1) b (+ a b)))) => 55
    try expectVMEvalInt(alloc, &env,
        "(loop [i 0 a 0 b 1] (if (= i 10) a (recur (+ i 1) b (+ a b))))", 55);

    // (loop [i 0 sum 0] (if (= i 10) sum (recur (+ i 1) (+ sum i)))) => 45
    try expectVMEvalInt(alloc, &env,
        "(loop [i 0 sum 0] (if (= i 10) sum (recur (+ i 1) (+ sum i))))", 45);
}

test "evalStringVM - fn-level recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // (fn [n] (if (> n 0) (recur (dec n)) n)) called with 3 => 0
    try expectVMEvalInt(alloc, &env,
        "((fn [n] (if (> n 0) (recur (dec n)) n)) 3)", 0);
}

test "evalString - fn-level recur (TreeWalk)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env,
        "((fn [n] (if (> n 0) (recur (dec n)) n)) 3)");
    try testing.expectEqual(Value.initInteger(0), result);
}

test "evalStringVM - higher-order fn (map via dispatcher)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // map is a TreeWalk closure from core.clj; inc is also a TW closure
    // VM should dispatch both through fn_val_dispatcher
    try expectVMEvalInt(alloc, &env, "(count (map inc [1 2 3]))", 3);
}

test "evalStringVM - multi-arity fn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Multi-arity: select by argument count
    try expectVMEvalInt(alloc, &env, "((fn ([x] x) ([x y] (+ x y))) 5)", 5);
    try expectVMEvalInt(alloc, &env, "((fn ([x] x) ([x y] (+ x y))) 3 4)", 7);
}

test "evalStringVM - def fn then call across forms (T9.5.1)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Two separate top-level forms: def creates fn_val in form 1,
    // form 2 calls it. This crosses Compiler boundaries in evalStringVM.
    try expectVMEvalInt(alloc, &env, "(def f (fn [x] (+ x 1))) (f 5)", 6);

    // Multiple defs across forms, then cross-call
    try expectVMEvalInt(alloc, &env,
        "(def add2 (fn [x] (+ x 2))) (def add3 (fn [x] (+ x 3))) (+ (add2 10) (add3 10))",
        25,
    );
}

test "swap! with fn_val closure (T9.5.2)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // swap! with a user-defined closure (fn_val), not a builtin_fn
    try expectEvalInt(alloc, &env,
        "(def a (atom 10)) (swap! a (fn [x] (+ x 5))) @a",
        15,
    );

    // swap! with fn_val and extra args
    try expectEvalInt(alloc, &env,
        "(def b (atom 0)) (swap! b (fn [x y z] (+ x y z)) 3 7) @b",
        10,
    );
}

test "seq on map (T9.5.3)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // (seq {:a 1}) => ([:a 1]) — count is 1
    try expectEvalInt(alloc, &env, "(count (seq {:a 1 :b 2}))", 2);

    // (first {:a 1}) => [:a 1] — first entry is a vector
    try expectEvalBool(alloc, &env, "(vector? (first {:a 1}))", true);

    // (count (first {:a 1})) => 2 — MapEntry has 2 elements
    try expectEvalInt(alloc, &env, "(count (first {:a 1}))", 2);

    // seq on empty map returns nil
    try expectEvalNil(alloc, &env, "(seq {})");
}

test "bound? and defonce (T9.5.5)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // bound? on undefined symbol
    try expectEvalBool(alloc, &env, "(bound? 'undefined-sym-xyz)", false);

    // bound? on defined symbol
    try expectEvalBool(alloc, &env, "(do (def my-var 42) (bound? 'my-var))", true);

    // defonce: first time defines, second time does not re-evaluate
    try expectEvalInt(alloc, &env, "(do (defonce x 10) x)", 10);
    try expectEvalInt(alloc, &env, "(do (defonce x 999) x)", 10); // still 10
}

// =========================================================================
// Destructuring tests (T4.9)
// =========================================================================

test "destructuring - sequential basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Basic sequential destructuring in let
    try expectEvalInt(alloc, &env, "(let [[a b] [1 2]] (+ a b))", 3);
    try expectEvalInt(alloc, &env, "(let [[a b c] [10 20 30]] (+ a c))", 40);
}

test "destructuring - sequential rest" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // & rest binding
    try expectEvalInt(alloc, &env, "(let [[a & r] [1 2 3]] a)", 1);
    try expectEvalInt(alloc, &env, "(let [[a & r] [1 2 3]] (count r))", 2);
    try expectEvalInt(alloc, &env, "(let [[a b & r] [1 2 3 4 5]] (first r))", 3);
}

test "destructuring - sequential :as" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // :as whole-collection binding
    try expectEvalInt(alloc, &env, "(let [[a b :as all] [1 2 3]] (count all))", 3);
    try expectEvalInt(alloc, &env, "(let [[a :as all] [10 20]] (+ a (count all)))", 12);
}

test "destructuring - map :keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // :keys destructuring
    try expectEvalInt(alloc, &env, "(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))", 3);
    try expectEvalInt(alloc, &env, "(let [{:keys [x]} {:x 42}] x)", 42);
}

test "destructuring - map :or defaults" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // :or default values
    try expectEvalInt(alloc, &env, "(let [{:keys [a] :or {a 99}} {}] a)", 99);
    try expectEvalInt(alloc, &env, "(let [{:keys [a] :or {a 99}} {:a 1}] a)", 1);
}

test "destructuring - map :as" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // :as whole-map binding
    try expectEvalInt(alloc, &env, "(let [{:keys [a] :as m} {:a 1 :b 2}] (+ a (count m)))", 3);
}

test "destructuring - map symbol keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // {x :x} style
    try expectEvalInt(alloc, &env, "(let [{x :x y :y} {:x 10 :y 20}] (+ x y))", 30);
}

test "destructuring - fn params" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Sequential destructuring in fn params
    try expectEvalInt(alloc, &env, "((fn [[a b]] (+ a b)) [1 2])", 3);
    // Map destructuring in fn params
    try expectEvalInt(alloc, &env, "((fn [{:keys [x y]}] (+ x y)) {:x 3 :y 4})", 7);
}

test "destructuring - loop" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Sequential destructuring in loop
    try expectEvalInt(alloc, &env, "(loop [[a b] [1 2]] (+ a b))", 3);
}

test "destructuring - nested" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Nested sequential destructuring
    try expectEvalInt(alloc, &env, "(let [[[a b] c] [[1 2] 3]] (+ a b c))", 6);
    // Map inside sequential
    try expectEvalInt(alloc, &env, "(let [[{:keys [x]} y] [{:x 10} 20]] (+ x y))", 30);
}

test "destructuring - VM sequential" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectVMEvalInt(alloc, &env, "(let [[a b] [1 2]] (+ a b))", 3);
    try expectVMEvalInt(alloc, &env, "(let [[a & r] [1 2 3]] a)", 1);
    try expectVMEvalInt(alloc, &env, "(let [[a b :as all] [1 2 3]] (count all))", 3);
}

test "destructuring - VM map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectVMEvalInt(alloc, &env, "(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))", 3);
    try expectVMEvalInt(alloc, &env, "(let [{:keys [a] :or {a 99}} {}] a)", 99);
}

test "destructuring - VM fn params" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectVMEvalInt(alloc, &env, "((fn [[a b]] (+ a b)) [1 2])", 3);
}

// =========================================================================
// for macro tests (T4.10)
// =========================================================================

test "core.clj - mapcat" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // mapcat: (mapcat (fn [x] (list x x)) [1 2 3]) => (1 1 2 2 3 3)
    try expectEvalInt(alloc, &env, "(count (mapcat (fn [x] (list x x)) [1 2 3]))", 6);
    try expectEvalInt(alloc, &env, "(first (mapcat (fn [x] (list x x)) [1 2 3]))", 1);
}

test "core.clj - for comprehension" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Single binding
    try expectEvalInt(alloc, &env, "(count (for [x [1 2 3]] (* x 2)))", 3);
    try expectEvalInt(alloc, &env, "(first (for [x [1 2 3]] (* x 2)))", 2);
    // Nested bindings: (for [x [1 2] y [10 20]] (+ x y)) => (11 21 12 22)
    try expectEvalInt(alloc, &env, "(count (for [x [1 2] y [10 20]] (+ x y)))", 4);
    try expectEvalInt(alloc, &env, "(first (for [x [1 2] y [10 20]] (+ x y)))", 11);
    // :when modifier
    try expectEvalInt(alloc, &env, "(count (for [x [1 2 3 4 5] :when (odd? x)] x))", 3);
    try expectEvalInt(alloc, &env, "(first (for [x [1 2 3 4 5] :when (odd? x)] x))", 1);
    // :let modifier
    try expectEvalInt(alloc, &env, "(first (for [x [1 2 3] :let [y (* x 10)]] y))", 10);
}

test "defprotocol - basic definition" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // defprotocol should define the protocol and its method vars
    _ = try evalString(alloc, &env, "(defprotocol IGreet (greet [this]))");
    // The method var 'greet' should be resolvable (test by evaluating it)
    // If not defined, this will error
    const greet_val = try evalString(alloc, &env, "greet");
    // It should be a protocol_fn value
    try testing.expect(greet_val.tag() == .protocol_fn);

    // extend-type and protocol dispatch
    _ = try evalString(alloc, &env,
        \\(extend-type String IGreet
        \\  (greet [this] (str "Hello, " this "!")))
    );
    try expectEvalStr(alloc, &env,
        \\(greet "World")
    , "Hello, World!");

    // Multiple type implementations
    _ = try evalString(alloc, &env,
        \\(extend-type Integer IGreet
        \\  (greet [this] (str "Number " this)))
    );
    try expectEvalStr(alloc, &env, "(greet 42)", "Number 42");

    // Multi-arity method
    _ = try evalString(alloc, &env, "(defprotocol IAdd (add-to [this x]))");
    _ = try evalString(alloc, &env,
        \\(extend-type Integer IAdd
        \\  (add-to [this x] (+ this x)))
    );
    try expectEvalInt(alloc, &env, "(add-to 10 20)", 30);

    // satisfies?
    try expectEvalBool(alloc, &env, "(satisfies? IGreet \"hello\")", true);
    try expectEvalBool(alloc, &env, "(satisfies? IGreet 42)", true);
    try expectEvalBool(alloc, &env, "(satisfies? IGreet [1 2])", false);
}

test "defprotocol - extend-via-metadata" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Define protocol with :extend-via-metadata true, create impl via metadata
    _ = try evalString(alloc, &env,
        \\(do
        \\  (defprotocol Describable
        \\    :extend-via-metadata true
        \\    (describe [this]))
        \\  (def obj (with-meta {:name "test"}
        \\             {(symbol "user" "describe") (fn [this] (str "I am " (:name this)))})))
    );
    try expectEvalStr(alloc, &env, "(describe obj)", "I am test");

    // Object without metadata should fall through to impls
    _ = try evalString(alloc, &env,
        \\(extend-type PersistentArrayMap Describable
        \\  (describe [this] "a map"))
    );
    try expectEvalStr(alloc, &env, "(describe {:x 1})", "a map");

    // Metadata-extended object should still use metadata (takes priority)
    try expectEvalStr(alloc, &env, "(describe obj)", "I am test");
}

test "defrecord - basic constructor" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defrecord Point [x y])");
    try expectEvalInt(alloc, &env, "(:x (->Point 1 2))", 1);
    try expectEvalInt(alloc, &env, "(:y (->Point 1 2))", 2);
}

// =========================================================================
// core.clj expansion tests
// =========================================================================

test "core.clj - get-in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(get-in {:a {:b 42}} [:a :b])", 42);
    try expectEvalNil(alloc, &env, "(get-in {:a 1} [:b :c])");
}

test "core.clj - assoc-in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(get-in (assoc-in {} [:a :b] 42) [:a :b])", 42);
}

test "core.clj - update" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(:a (update {:a 1} :a inc))", 2);
}

test "core.clj - update-in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(get-in (update-in {:a {:b 1}} [:a :b] inc) [:a :b])", 2);
}

test "core.clj - select-keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (select-keys {:a 1 :b 2 :c 3} [:a :c]))", 2);
    try expectEvalInt(alloc, &env, "(:a (select-keys {:a 1 :b 2} [:a]))", 1);
}

test "core.clj - some" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(some even? [1 2 3])", true);
    try expectEvalNil(alloc, &env, "(some even? [1 3 5])");
}

test "core.clj - every?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(every? even? [2 4 6])", true);
    try expectEvalBool(alloc, &env, "(every? even? [2 3 6])", false);
}

test "core.clj - not-every?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(not-every? even? [2 4 6])", false);
    try expectEvalBool(alloc, &env, "(not-every? even? [2 3 6])", true);
}

test "core.clj - partial" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "((partial + 10) 5)", 15);
    try expectEvalInt(alloc, &env, "((partial + 1 2) 3)", 6);
}

test "core.clj - comp" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "((comp inc inc) 0)", 2);
}

test "core.clj - if-let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(if-let [x 42] x 0)", 42);
    try expectEvalInt(alloc, &env, "(if-let [x nil] 1 0)", 0);
}

test "core.clj - when-let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(when-let [x 42] x)", 42);
    try expectEvalNil(alloc, &env, "(when-let [x nil] 42)");
}

test "core.clj - range" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (range 5))", 5);
    try expectEvalInt(alloc, &env, "(first (range 3))", 0);
    try expectEvalInt(alloc, &env, "(count (range 2 8))", 6);
}

test "core.clj - empty?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(empty? [])", true);
    try expectEvalBool(alloc, &env, "(empty? [1])", false);
    try expectEvalBool(alloc, &env, "(empty? nil)", true);
}

test "core.clj - contains?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(contains? {:a 1} :a)", true);
    try expectEvalBool(alloc, &env, "(contains? {:a 1} :b)", false);
}

test "core.clj - keys and vals" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (keys {:a 1 :b 2}))", 2);
    try expectEvalInt(alloc, &env, "(reduce + 0 (vals {:a 1 :b 2}))", 3);
}

test "core.clj - partition" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (partition 2 [1 2 3 4 5]))", 2);
    try expectEvalInt(alloc, &env, "(count (first (partition 2 [1 2 3 4])))", 2);
}

test "core.clj - group-by" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (group-by even? [1 2 3 4 5]))", 2);
}

test "core.clj - flatten" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (flatten [[1 2] [3 [4 5]]]))", 5);
    try expectEvalInt(alloc, &env, "(first (flatten [[1 2] [3]]))", 1);
}

test "core.clj - interleave" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (interleave [1 2 3] [4 5 6]))", 6);
    try expectEvalInt(alloc, &env, "(first (interleave [1 2] [3 4]))", 1);
}

test "core.clj - interpose" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (interpose 0 [1 2 3]))", 5);
}

test "core.clj - distinct" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (distinct [1 2 1 3 2]))", 3);
}

test "core.clj - frequencies" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(get (frequencies [1 1 2 3 3 3]) 3)", 3);
    try expectEvalInt(alloc, &env, "(count (frequencies [1 2 3]))", 3);
}

test "evalString - call depth limit prevents crash" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Define a non-tail-recursive function
    _ = try evalString(alloc, &env, "(def deep (fn [n] (if (= n 0) 0 (+ 1 (deep (- n 1))))))");

    // Small depth should succeed
    try expectEvalInt(alloc, &env, "(deep 10)", 10);

    // Moderate depth should succeed (within MAX_CALL_DEPTH)
    try expectEvalInt(alloc, &env, "(deep 100)", 100);

    // Exceeding MAX_CALL_DEPTH (512, TreeWalk) should return error, not crash
    const result = evalString(alloc, &env, "(deep 520)");
    try testing.expectError(error.EvalError, result);
}

test "core.clj - doto macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // doto returns the original value
    try expectEvalInt(alloc, &env, "(doto 42 identity inc)", 42);
}

test "core.clj - as-> macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // as-> lets you name the threaded value and place it anywhere
    try expectEvalInt(alloc, &env, "(as-> 1 x (+ x 10) (- x 5))", 6);
    try expectEvalStr(alloc, &env, "(as-> 42 x (str \"value=\" x))", "value=42");
}

test "core.clj - some-> macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // some-> threads value through forms, short-circuits on nil
    try expectEvalInt(alloc, &env, "(some-> 1 inc inc)", 3);
    try expectEvalNil(alloc, &env, "(some-> nil inc inc)");
}

test "core.clj - cond-> macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // cond-> threads value through forms where condition is true
    try expectEvalInt(alloc, &env, "(cond-> 1 true inc false inc)", 2);
    try expectEvalInt(alloc, &env, "(cond-> 1 true inc true inc)", 3);
}

test "defmulti/defmethod - basic dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Define a multimethod dispatching on :shape key
    _ = try evalString(alloc, &env,
        \\(defmulti area :shape)
        \\(defmethod area :circle [x] (* 3 (:radius x) (:radius x)))
        \\(defmethod area :rect [x] (* (:width x) (:height x)))
    );

    try expectEvalInt(alloc, &env, "(area {:shape :circle :radius 5})", 75);
    try expectEvalInt(alloc, &env, "(area {:shape :rect :width 3 :height 4})", 12);
}

test "defmulti/defmethod - default method" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env,
        \\(defmulti greet identity)
        \\(defmethod greet :en [_] "hello")
        \\(defmethod greet :default [_] "hi")
    );

    try expectEvalStr(alloc, &env, "(greet :en)", "hello");
    try expectEvalStr(alloc, &env, "(greet :fr)", "hi");
}

test "try/catch/throw - basic exception" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(try (throw "oops") (catch Exception e (str "caught: " e)))
    , "caught: oops");
}

test "try/catch/throw - no exception" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(try (+ 1 2) (catch Exception e 0))", 3);
}

test "try/catch/throw - throw map value" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(try (throw {:type :err :msg "bad"}) (catch Exception e (:msg e)))
    , "bad");
}

test "ex-info and ex-data" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(try (throw (ex-info "boom" {:code 42}))
        \\  (catch Exception e (ex-message e)))
    , "boom");

    try expectEvalInt(alloc, &env,
        \\(try (throw (ex-info "boom" {:code 42}))
        \\  (catch Exception e (:code (ex-data e))))
    , 42);
}

test "try/catch/finally" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // finally runs but return value is from catch
    try expectEvalStr(alloc, &env,
        \\(try (throw "x") (catch Exception e e) (finally nil))
    , "x");
}

test "lazy-seq - basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // lazy-seq wrapping cons produces a seq
    try expectEvalInt(alloc, &env,
        \\(first (lazy-seq (cons 42 nil)))
    , 42);
}

test "lazy-seq - iterate with take" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Define iterate using lazy-seq
    _ = try evalString(alloc, &env,
        \\(defn my-iterate [f x]
        \\  (lazy-seq (cons x (my-iterate f (f x)))))
    );

    try expectEvalInt(alloc, &env, "(first (my-iterate inc 0))", 0);
    try expectEvalInt(alloc, &env, "(first (rest (my-iterate inc 0)))", 1);
    try expectEvalInt(alloc, &env, "(first (rest (rest (my-iterate inc 0))))", 2);
}

test "lazy-seq - take from infinite sequence" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Build lazy iterate + take
    _ = try evalString(alloc, &env,
        \\(defn my-iterate [f x]
        \\  (lazy-seq (cons x (my-iterate f (f x)))))
    );

    // take 5 from infinite sequence
    const raw_result = try evalString(alloc, &env,
        \\(take 5 (my-iterate inc 0))
    );
    // Should be (0 1 2 3 4) or [0 1 2 3 4]
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw_result);
    try std.testing.expect(result.tag() == .list or result.tag() == .vector);
}

test "core.clj - mapv" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(mapv inc [1 2 3])");
    try std.testing.expect(result.tag() == .vector);
    try std.testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try std.testing.expectEqual(Value.initInteger(2), result.asVector().items[0]);
    try std.testing.expectEqual(Value.initInteger(3), result.asVector().items[1]);
    try std.testing.expectEqual(Value.initInteger(4), result.asVector().items[2]);
}

test "core.clj - reduce-kv" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // reduce-kv sums values of a map
    const result = try evalString(alloc, &env,
        \\(reduce-kv (fn [acc k v] (+ acc v)) 0 {:a 1 :b 2 :c 3})
    );
    try std.testing.expectEqual(Value.initInteger(6), result);
}

test "core.clj - reduce-kv builds new map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // reduce-kv that transforms values
    const result = try evalString(alloc, &env,
        \\(reduce-kv (fn [acc k v] (assoc acc k (inc v))) {} {:a 1 :b 2})
    );
    try std.testing.expect(result.tag() == .map);
    // Check the map has 2 entries with incremented values
    try std.testing.expectEqual(@as(usize, 2), result.asMap().count());
}

test "core.clj - filterv" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn even? [x] (= 0 (rem x 2)))");
    const result = try evalString(alloc, &env, "(filterv even? [1 2 3 4 5 6])");
    try std.testing.expect(result.tag() == .vector);
    try std.testing.expectEqual(@as(usize, 3), result.asVector().items.len);
    try std.testing.expectEqual(Value.initInteger(2), result.asVector().items[0]);
    try std.testing.expectEqual(Value.initInteger(4), result.asVector().items[1]);
    try std.testing.expectEqual(Value.initInteger(6), result.asVector().items[2]);
}

test "core.clj - partition-all" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // partition-all includes trailing incomplete chunk
    const raw_result = try evalString(alloc, &env, "(partition-all 3 [1 2 3 4 5])");
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw_result);
    try std.testing.expect(result.tag() == .list);
    try std.testing.expectEqual(@as(usize, 2), result.asList().items.len);
    // First chunk: (1 2 3)
    const chunk1 = try builtin_collections.realizeValue(alloc, result.asList().items[0]);
    try std.testing.expect(chunk1.tag() == .list);
    try std.testing.expectEqual(@as(usize, 3), chunk1.asList().items.len);
    // Second chunk: (4 5) — incomplete
    const chunk2 = try builtin_collections.realizeValue(alloc, result.asList().items[1]);
    try std.testing.expect(chunk2.tag() == .list);
    try std.testing.expectEqual(@as(usize, 2), chunk2.asList().items.len);
}

test "core.clj - take-while" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn pos? [x] (> x 0))");
    const raw_result = try evalString(alloc, &env, "(take-while pos? [3 2 1 0 -1])");
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw_result);
    try std.testing.expect(result.tag() == .list);
    try std.testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try std.testing.expectEqual(Value.initInteger(3), result.asList().items[0]);
    try std.testing.expectEqual(Value.initInteger(2), result.asList().items[1]);
    try std.testing.expectEqual(Value.initInteger(1), result.asList().items[2]);
}

test "core.clj - drop-while" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn pos? [x] (> x 0))");
    const result = try evalString(alloc, &env, "(drop-while pos? [3 2 1 0 -1])");
    try std.testing.expect(result.tag() == .list);
    try std.testing.expectEqual(@as(usize, 2), result.asList().items.len);
    try std.testing.expectEqual(Value.initInteger(0), result.asList().items[0]);
    try std.testing.expectEqual(Value.initInteger(-1), result.asList().items[1]);
}

test "core.clj - last" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(last [1 2 3 4 5])");
    try std.testing.expectEqual(Value.initInteger(5), result);

    const r2 = try evalString(alloc, &env, "(last [42])");
    try std.testing.expectEqual(Value.initInteger(42), r2);

    const r3 = try evalString(alloc, &env, "(last [])");
    try std.testing.expectEqual(Value.nil_val, r3);
}

test "core.clj - butlast" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(butlast [1 2 3 4])");
    try std.testing.expect(result.tag() == .list);
    try std.testing.expectEqual(@as(usize, 3), result.asList().items.len);
    try std.testing.expectEqual(Value.initInteger(1), result.asList().items[0]);
    try std.testing.expectEqual(Value.initInteger(3), result.asList().items[2]);

    const r2 = try evalString(alloc, &env, "(butlast [1])");
    try std.testing.expectEqual(Value.nil_val, r2);
}

test "core.clj - second" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(second [10 20 30])");
    try std.testing.expectEqual(Value.initInteger(20), result);
}

test "core.clj - fnext" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // fnext = first of next = second
    const result = try evalString(alloc, &env, "(fnext [10 20 30])");
    try std.testing.expectEqual(Value.initInteger(20), result);
}

test "core.clj - nfirst" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // nfirst = next of first; first of [[1 2] [3 4]] is [1 2], next of that is (2)
    const result = try evalString(alloc, &env, "(nfirst [[1 2] [3 4]])");
    try std.testing.expect(result.tag() == .list);
    try std.testing.expectEqual(@as(usize, 1), result.asList().items.len);
    try std.testing.expectEqual(Value.initInteger(2), result.asList().items[0]);
}

test "core.clj - not-empty" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // non-empty collection returns itself
    const r1 = try evalString(alloc, &env, "(not-empty [1 2 3])");
    try std.testing.expect(r1.tag() == .vector);
    try std.testing.expectEqual(@as(usize, 3), r1.asVector().items.len);

    // empty collection returns nil
    const r2 = try evalString(alloc, &env, "(not-empty [])");
    try std.testing.expectEqual(Value.nil_val, r2);
}

test "core.clj - every-pred" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn pos? [x] (> x 0))");
    _ = try evalString(alloc, &env, "(defn even? [x] (= 0 (rem x 2)))");

    // every-pred combines two predicates
    const r1 = try evalString(alloc, &env, "((every-pred pos? even?) 4)");
    try std.testing.expect(r1.tag() != .nil);

    const r2 = try evalString(alloc, &env, "((every-pred pos? even?) 3)");
    try std.testing.expect(r2.tag() == .boolean and r2.asBoolean() == false);
}

test "core.clj - some-fn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn pos? [x] (> x 0))");
    _ = try evalString(alloc, &env, "(defn even? [x] (= 0 (rem x 2)))");

    // some-fn: at least one predicate returns truthy
    const r1 = try evalString(alloc, &env, "((some-fn pos? even?) -2)");
    try std.testing.expect(r1.tag() != .nil);

    const r2 = try evalString(alloc, &env, "((some-fn pos? even?) -3)");
    // -3 is not positive and not even => falsy (false or nil depending on or impl)
    try std.testing.expect(r2.tag() == .nil or (r2.tag() == .boolean and r2.asBoolean() == false));
}

test "core.clj - fnil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // fnil replaces nil with default
    const result = try evalString(alloc, &env, "((fnil inc 0) nil)");
    try std.testing.expectEqual(Value.initInteger(1), result);

    // non-nil passes through
    const r2 = try evalString(alloc, &env, "((fnil inc 0) 5)");
    try std.testing.expectEqual(Value.initInteger(6), r2);
}

test "core.clj - doseq" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // doseq iterates for side effects, returns nil
    const result = try evalString(alloc, &env,
        \\(let [a (atom 0)]
        \\  (doseq [x [1 2 3]]
        \\    (swap! a + x))
        \\  (deref a))
    );
    try std.testing.expectEqual(Value.initInteger(6), result);
}

test "core.clj - doall" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // doall forces lazy seq and returns it
    const raw_result = try evalString(alloc, &env, "(doall (map inc [1 2 3]))");
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw_result);
    try std.testing.expect(result.tag() == .list);
    try std.testing.expectEqual(@as(usize, 3), result.asList().items.len);
}

test "core.clj - dorun" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // dorun walks seq, returns nil
    const result = try evalString(alloc, &env, "(dorun (map inc [1 2 3]))");
    try std.testing.expectEqual(Value.nil_val, result);
}

test "core.clj - while" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // while loop with atom — use builtin + for swap!
    const result = try evalString(alloc, &env,
        \\(let [a (atom 0)]
        \\  (while (< (deref a) 5)
        \\    (swap! a + 1))
        \\  (deref a))
    );
    try std.testing.expectEqual(Value.initInteger(5), result);
}

test "core.clj - case" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(case 2 1 :a 2 :b 3 :c)");
    try std.testing.expect(r1.tag() == .keyword);

    // default case
    const r2 = try evalString(alloc, &env, "(case 99 1 :a 2 :b :default)");
    try std.testing.expect(r2.tag() == .keyword);
}

test "core.clj - condp" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env,
        \\(condp = 2
        \\  1 :a
        \\  2 :b
        \\  3 :c)
    );
    try std.testing.expect(result.tag() == .keyword);
}

test "core.clj - declare" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(declare my-forward-fn)");
    // Should be nil (declared but not defined)
    const result = try evalString(alloc, &env, "my-forward-fn");
    try std.testing.expectEqual(Value.nil_val, result);

    // Now define it
    _ = try evalString(alloc, &env, "(defn my-forward-fn [x] (+ x 1))");
    const r2 = try evalString(alloc, &env, "(my-forward-fn 5)");
    try std.testing.expectEqual(Value.initInteger(6), r2);
}

test "core.clj - delay and force" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // delay creates a deferred computation, force evaluates it
    const result = try evalString(alloc, &env,
        \\(let [d (delay (+ 1 2))]
        \\  (force d))
    );
    try std.testing.expectEqual(Value.initInteger(3), result);
}

test "core.clj - delay memoizes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // force should return same value on repeated calls (memoized)
    const result = try evalString(alloc, &env,
        \\(let [counter (atom 0)
        \\      d (delay (do (swap! counter + 1) (deref counter)))]
        \\  (force d)
        \\  (force d)
        \\  (deref counter))
    );
    // Counter should be 1 (thunk evaluated only once)
    try std.testing.expectEqual(Value.initInteger(1), result);
}

test "core.clj - realized?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env,
        \\(let [d (delay (+ 1 2))]
        \\  (let [before (realized? d)]
        \\    (force d)
        \\    (let [after (realized? d)]
        \\      (list before after))))
    );
    // before=false, after=true
    try std.testing.expect(result.tag() == .list);
    try std.testing.expectEqual(@as(usize, 2), result.asList().items.len);
    try std.testing.expect(result.asList().items[0].tag() == .boolean and result.asList().items[0].asBoolean() == false);
    try std.testing.expect(result.asList().items[1].tag() == .boolean and result.asList().items[1].asBoolean() == true);
}

test "core.clj - boolean" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(boolean 42)");
    try std.testing.expect(r1.tag() == .boolean and r1.asBoolean() == true);

    const r2 = try evalString(alloc, &env, "(boolean nil)");
    try std.testing.expect(r2.tag() == .boolean and r2.asBoolean() == false);

    const r3 = try evalString(alloc, &env, "(boolean false)");
    try std.testing.expect(r3.tag() == .boolean and r3.asBoolean() == false);
}

test "core.clj - true? false? some? any?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(true? true)");
    try std.testing.expect(r1.tag() == .boolean and r1.asBoolean() == true);

    const r2 = try evalString(alloc, &env, "(true? 1)");
    try std.testing.expect(r2.tag() == .boolean and r2.asBoolean() == false);

    const r3 = try evalString(alloc, &env, "(false? false)");
    try std.testing.expect(r3.tag() == .boolean and r3.asBoolean() == true);

    const r4 = try evalString(alloc, &env, "(false? nil)");
    try std.testing.expect(r4.tag() == .boolean and r4.asBoolean() == false);

    const r5 = try evalString(alloc, &env, "(some? 42)");
    try std.testing.expect(r5.tag() == .boolean and r5.asBoolean() == true);

    const r6 = try evalString(alloc, &env, "(some? nil)");
    try std.testing.expect(r6.tag() == .boolean and r6.asBoolean() == false);

    const r7 = try evalString(alloc, &env, "(any? nil)");
    try std.testing.expect(r7.tag() == .boolean and r7.asBoolean() == true);
}

test "core.clj - type" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // type returns keyword for value type
    const r1 = try evalString(alloc, &env, "(type 42)");
    try std.testing.expect(r1.tag() == .keyword);
    try std.testing.expectEqualStrings("integer", r1.asKeyword().name);

    const r2 = try evalString(alloc, &env, "(type \"hello\")");
    try std.testing.expect(r2.tag() == .keyword);
    try std.testing.expectEqualStrings("string", r2.asKeyword().name);

    const r3 = try evalString(alloc, &env, "(type :foo)");
    try std.testing.expect(r3.tag() == .keyword);
    try std.testing.expectEqualStrings("keyword", r3.asKeyword().name);

    const r4 = try evalString(alloc, &env, "(type [1 2])");
    try std.testing.expect(r4.tag() == .keyword);
    try std.testing.expectEqualStrings("vector", r4.asKeyword().name);

    const r5 = try evalString(alloc, &env, "(type nil)");
    try std.testing.expect(r5.tag() == .keyword);
    try std.testing.expectEqualStrings("nil", r5.asKeyword().name);
}

test "core.clj - instance?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(instance? :integer 42)");
    try std.testing.expect(r1.tag() == .boolean and r1.asBoolean() == true);

    const r2 = try evalString(alloc, &env, "(instance? :string 42)");
    try std.testing.expect(r2.tag() == .boolean and r2.asBoolean() == false);
}

test "evalStringVM - TreeWalk→VM reverse dispatch (T10.2)" {
    // When VM evaluates `(map (fn [x] (* x x)) [1 2 3])`:
    //   1. VM compiles `(fn [x] (* x x))` to bytecode fn_val (kind=.bytecode)
    //   2. VM calls `map` — which is a TreeWalk closure from core.clj
    //   3. `map` calls back the bytecode fn via TreeWalk's callValue
    //   4. TreeWalk must detect kind=.bytecode and dispatch to VM
    // Without reverse dispatch, step 4 segfaults (Closure ptr != FnProto ptr).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // map with fn callback — wrap in vec to force realization within VM context
    const r1 = try evalStringVM(alloc, &env, "(vec (map (fn [x] (* x x)) [1 2 3]))");
    try testing.expect(r1.tag() == .vector);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r1.formatPrStr(&w);
    try testing.expectEqualStrings("[1 4 9]", w.buffered());

    // filter with fn callback — wrap in vec to force realization within VM context
    const r2 = try evalStringVM(alloc, &env, "(vec (filter (fn [x] (> x 2)) [1 2 3 4 5]))");
    try testing.expect(r2.tag() == .vector);
    var buf2: [256]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try r2.formatPrStr(&w2);
    try testing.expectEqualStrings("[3 4 5]", w2.buffered());

    // reduce with fn callback
    const r3 = try evalStringVM(alloc, &env, "(reduce (fn [acc x] (+ acc x)) 0 [1 2 3 4 5])");
    try testing.expectEqual(Value.initInteger(15), r3);
}

// === eval / read-string / macroexpand integration tests ===

test "read-string builtin via evalString" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(read-string \"42\")", 42);
}

test "read-string returns vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(read-string \"[1 2 3]\")");
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().items.len);
}

test "eval builtin - (eval '(+ 1 2))" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(eval '(+ 1 2))", 3);
}

test "eval builtin - eval constant" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(eval 42)", 42);
}

test "eval + read-string combined" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(eval (read-string \"(+ 10 20)\"))", 30);
}

test "macroexpand-1 on non-macro returns unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Non-macro form should return unchanged
    try expectEvalInt(alloc, &env, "(macroexpand-1 42)", 42);
}

test "macroexpand-1 expands when macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // (when true 1) should expand to (if true (do 1))
    const raw = try evalString(alloc, &env, "(macroexpand-1 '(when true 1))");
    // Lazy concat in syntax-quote may produce cons/lazy_seq; realize to list
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw);
    try testing.expect(result.tag() == .list);
    // First element should be 'if' symbol
    try testing.expect(result.asList().items[0].tag() == .symbol);
    try testing.expectEqualStrings("if", result.asList().items[0].asSymbol().name);
}

test "macroexpand fully expands nested macros" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // (when true 1) -> macroexpand should fully expand
    const raw = try evalString(alloc, &env, "(macroexpand '(when true 1))");
    const prev = setupMacroEnv(&env);
    defer restoreMacroEnv(prev);
    const result = try builtin_collections.realizeValue(alloc, raw);
    try testing.expect(result.tag() == .list);
    try testing.expect(result.asList().items[0].tag() == .symbol);
    try testing.expectEqualStrings("if", result.asList().items[0].asSymbol().name);
}

test "bootstrap cache - round-trip: generate and restore" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    defer value_mod.resetPrintVars(); // Clean up global state after arena freed
    const alloc = arena.allocator();

    // Phase 1: Full bootstrap + generate cache
    var env1 = Env.init(alloc);
    try registry.registerBuiltins(&env1);
    try loadBootstrapAll(alloc, &env1);

    const cache_bytes = try generateBootstrapCache(alloc, &env1);

    // Phase 2: Restore from cache into fresh env (use eager restore for round-trip test)
    var env2 = Env.init(alloc);
    try registry.registerBuiltins(&env2);
    {
        var de: serialize_mod.Deserializer = .{ .data = cache_bytes };
        try de.restoreEnvSnapshot(alloc, &env2);
    }

    // Verify: basic arithmetic via builtins
    const r1 = try evalStringVM(alloc, &env2, "(+ 1 2)");
    try testing.expectEqual(Value.initInteger(3), r1);

    // Verify: core fn (inc) works
    const r2 = try evalStringVM(alloc, &env2, "(inc 41)");
    try testing.expectEqual(Value.initInteger(42), r2);

    // Verify: core macro (when) works
    const r3 = try evalStringVM(alloc, &env2, "(when true 99)");
    try testing.expectEqual(Value.initInteger(99), r3);

    // Verify: defn + call works
    const r4 = try evalStringVM(alloc, &env2, "(defn f [x] (* x 2)) (f 5)");
    try testing.expectEqual(Value.initInteger(10), r4);

    // Verify: map (hot_core_defs function) works
    const r5 = try evalStringVM(alloc, &env2,
        \\(apply + (map inc [1 2 3]))
    );
    try testing.expectEqual(Value.initInteger(9), r5);

    // Verify: filter works
    const r6 = try evalStringVM(alloc, &env2,
        \\(count (filter odd? [1 2 3 4 5]))
    );
    try testing.expectEqual(Value.initInteger(3), r6);

    // Verify: macros from clojure.test namespace available
    const test_ns = env2.findNamespace("clojure.test");
    try testing.expect(test_ns != null);
}

test "compileToModule - compile and run bytecode" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Compile source to bytecode Module
    const module_bytes = try compileToModule(alloc, &env,
        \\(+ 10 (* 3 4))
    );
    try testing.expect(module_bytes.len > 0);
    // Check CLJC magic
    try testing.expectEqualStrings("CLJC", module_bytes[0..4]);

    // Run the compiled Module in the same env
    const result = try runBytecodeModule(alloc, &env, module_bytes);
    try testing.expectEqual(Value.initInteger(22), result);
}

test "compileToModule - multi-form source" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Multi-form: defn + call. Only last form's value is returned.
    const module_bytes = try compileToModule(alloc, &env,
        \\(defn triple [x] (* x 3))
        \\(triple 7)
    );

    const result = try runBytecodeModule(alloc, &env, module_bytes);
    try testing.expectEqual(Value.initInteger(21), result);
}

test "compileToModule - uses core macros" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Source uses when macro from core.clj
    const module_bytes = try compileToModule(alloc, &env,
        \\(when (> 5 3) (+ 100 200))
    );

    const result = try runBytecodeModule(alloc, &env, module_bytes);
    try testing.expectEqual(Value.initInteger(300), result);
}
