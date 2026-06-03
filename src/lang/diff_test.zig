// SPDX-License-Identifier: EPL-2.0
//! Differential test cases — calls `eval.evaluator.compare` against a
//! Runtime + Env wired with the standard primitive + macro tables
//! (Phase 4 entry suite, ROADMAP §9.6 / 4.10).
//!
//! Lives in `lang/` because the fixture imports `primitive.registerAll`
//! and `macro_transforms.registerInto`, which are zone-1 modules
//! `eval/evaluator.zig` cannot reach (`zone_deps.md`).
//!
//! Each `test "diff: …"` block describes one source form whose
//! tree-walk and VM evaluations must agree. New cases land here as
//! the Phase-4 task list progresses; the harness scales with each
//! addition.

const std = @import("std");
const evaluator = @import("../eval/evaluator.zig");
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value/value.zig").Value;
const primitive = @import("primitive.zig");
const macro_transforms = @import("macro_transforms.zig");
const Reader = @import("../eval/reader.zig").Reader;
const analyze = @import("../eval/analyzer/analyzer.zig").analyze;
const driver = @import("../eval/driver.zig");
const vm_compiler = @import("../eval/backend/vm/compiler.zig");
const serialize = @import("../eval/bytecode/serialize.zig");
const tree_walk = @import("../eval/backend/tree_walk.zig");

const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    table: macro_dispatch.Table,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var f: Fixture = undefined;
        f.threaded = std.Io.Threaded.init(alloc, .{});
        f.rt = Runtime.init(f.threaded.io(), alloc);
        f.env = try Env.init(&f.rt);
        f.arena = std.heap.ArenaAllocator.init(alloc);
        f.table = macro_dispatch.Table.init(alloc);
        try primitive.registerAll(&f.env);
        try macro_transforms.registerInto(&f.env, &f.table);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn check(self: *Fixture, source: []const u8, expected: i64) !void {
        const r = evaluator.compare(&self.rt, &self.env, &self.table, self.arena.allocator(), source);
        try testing.expect(r.equal);
        try testing.expectEqual(expected, (try r.tree_walk).asInteger());
    }
};

test "diff: arithmetic primitive" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(+ 1 2 3)", 6);
}

test "diff: let* binding" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(let* [x 5] (+ x 10))", 15);
}

test "diff: letfn* mutual + self recursion" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // self-recursion resolves through the letfn slot (fact calls fact)
    try f.check("(letfn* [fact (fn* [n] (if (= n 0) 1 (* n (fact (- n 1)))))] (fact 5))", 120);
    // mutual recursion: ev/od cross-reference each other (4 is even → 1)
    try f.check("(letfn* [ev (fn* [n] (if (= n 0) 1 (od (- n 1)))) od (fn* [n] (if (= n 0) 0 (ev (- n 1))))] (ev 4))", 1);
}

test "diff: fn* immediate invocation" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("((fn* [x y] (+ x y)) 3 4)", 7);
}

test "diff: variadic single seq-shaped rest arg cons-wraps (ADR-0042 am1)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // A NORMAL call with one list trailing arg binds `xs = ((9 9))`
    // (count 1), NOT `(9 9)` (count 2). The shape-only ADR-0042 gate
    // got this wrong on both backends; the RestMode split fixes it.
    try f.check("(count ((fn* [a & xs] xs) 1 (quote (9 9))))", 1);
}

test "diff: apply spread still binds the trailing seq directly" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // apply's bind-direct path is preserved: xs = (2 3), count 2.
    try f.check("(count (apply (fn* [a & xs] xs) 1 (quote (2 3))))", 2);
    try f.check("(apply + (quote (1 2 3 4)))", 10);
}

test "diff: data structures + keywords as IFn (D-085)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // The dispatch arm lives in the shared treeWalkCall (VM op_call routes
    // through rt.vtable.callFn → treeWalkCall), so both backends agree.
    // Cases stay primitive-only (the Fixture has no core.clj, so no
    // map/filter; `apply` is a primitive and exercises the HOF path).
    try f.check("(:k {:k 42})", 42);
    try f.check("({:k 7} :k)", 7);
    try f.check("([10 20 30] 1)", 20);
    try f.check("(#{5} 5)", 5);
    try f.check("(apply :a [{:a 99}])", 99);
    try f.check("(apply {:x 5} [:x])", 5);
    try f.check("(apply [10 20 30] [2])", 30);
}

test "diff: atom — atom/deref/@/swap!/reset!/compare-and-set! (D-085 sibling)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Atom is a runtime value; the ops are primitives and `@` desugars at
    // the reader → (deref x). No analyzer Node / opcode, so both backends
    // agree. (Fixture has no core.clj, so cases stay primitive-only.)
    try f.check("(deref (atom 42))", 42);
    try f.check("@(atom 7)", 7);
    try f.check("(let* [a (atom 0)] (swap! a inc) @a)", 1);
    try f.check("(let* [a (atom 5)] (reset! a 9) @a)", 9);
    try f.check("(if (compare-and-set! (atom 1) 1 2) 100 200)", 100);
    // volatile shares the mutable-cell mechanism (primitives, no core.clj).
    try f.check("(let* [v (volatile! 0)] (vswap! v inc) @v)", 1);
    try f.check("(if (volatile? (volatile! 1)) 10 20)", 10);
}

test "diff: vector keys by value (D-092) — keyEqValue/valueHash backend-shared" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // map ops + equal.keyEqValue/valueHash live in runtime/ (both backends
    // share them), so a vector-keyed lookup agrees across backends.
    try f.check("(get {[1 2] 42} [1 2])", 42);
    try f.check("(get (assoc {[1] 1} [1] 9) [1])", 9);
    try f.check("(if (contains? {[1 2] :a} [1 2]) 10 20)", 10);
}

test "diff: map/set/list keys by value (D-092) — keyEqValue/valueHash backend-shared" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Collection-as-key content hash + equality (equal.zig + map/set.zig)
    // are runtime/, shared by both backends, so the lookups agree.
    // Collection KEYS are literals (the minimal fixture lacks core.clj, so
    // a runtime-call key like `(list 1 2)` is exercised in the e2e instead).
    try f.check("(get {{:a 1} 42} {:a 1})", 42); // map key
    try f.check("(count (assoc {} {:k 1} 1 {:k 1} 2))", 1); // dedup
    try f.check("(get {#{1 2} 7} #{2 1})", 7); // set key (order-indep)
    try f.check("(get {'(1 2) 5} '(1 2))", 5); // list key
    try f.check("(get {[1 2] 9} '(1 2))", 9); // cross vec≡list
    try f.check("(count #{{:a 1} {:a 1} {:a 2}})", 2); // set-literal dedup of map elems
    try f.check("(count (conj #{{:a 1}} {:a 1}))", 1); // set elem content dedup
}

test "diff: ::name auto-resolved keyword (D-195) — analyzer-shared resolution" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // `::name` resolves to the current ns (user) in the analyzer, which both
    // backends share. The Fixture's Env.init sets current_ns = user.
    try f.check("(if (= ::foo :user/foo) 1 0)", 1);
    try f.check("(count (name ::bar))", 3); // "bar"
    try f.check("(if (= ::a ::a) 1 0)", 1);
    try f.check("(get {::k 7} ::k)", 7); // map-literal key resolves
}

test "diff: contains? on a vector tests index validity — primitive, backend-shared" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(if (contains? [1 2 3] 2) 1 0)", 1); // valid index
    try f.check("(if (contains? [1 2 3] 5) 1 0)", 0); // out of range
    try f.check("(if (contains? [1 2 3] :x) 1 0)", 0); // non-integer → false, not error
}

test "diff: runtime metadata (meta / with-meta) — backend-shared" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // meta storage + the primitives live in runtime/; vary-meta is core.clj
    // (excluded from the Fixture). with-meta/meta agree across backends.
    try f.check("(get (meta (with-meta [1] {:a 7})) :a)", 7);
    try f.check("(if (nil? (meta [1 2])) 10 20)", 10);
    try f.check("(count (meta (with-meta {} {:a 1 :b 2})))", 2);
    try f.check("(get (meta (assoc (with-meta {:a 1} {:m 5}) :b 2)) :m)", 5);
}

test "diff: binding rebinds a dynamic var (both backends)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // No `^:dynamic` reader-metadata surface yet (D-075); mark a Var
    // dynamic directly (the env.zig unit-test pattern) so the binding
    // special form has a target on both backends.
    const user = f.env.findNs("user").?;
    const v = try f.env.intern(user, "*tv*", Value.initInteger(1), null);
    v.flags.dynamic = true;
    try f.check("(binding [*tv* 2] *tv*)", 2);
}

test "diff: set! updates the active thread binding (both backends)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const user = f.env.findNs("user").?;
    const v = try f.env.intern(user, "*tv*", Value.initInteger(1), null);
    v.flags.dynamic = true;
    // set! mutates the innermost frame; the form returns the assigned value.
    try f.check("(binding [*tv* 2] (set! *tv* 42) *tv*)", 42);
}

test "diff: set! at top level sets the var root (both backends)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const user = f.env.findNs("user").?;
    const v = try f.env.intern(user, "*tv*", Value.initInteger(1), null);
    v.flags.dynamic = true;
    // No active binding frame → set! writes the root; deref then sees it.
    try f.check("(do (set! *tv* 7) *tv*)", 7);
}

test "diff: binding restores the root after the dynamic extent" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const user = f.env.findNs("user").?;
    const v = try f.env.intern(user, "*tv*", Value.initInteger(1), null);
    v.flags.dynamic = true;
    // Inner binding yields 2; after it pops, *tv* is the root 1 again.
    try f.check("(do (binding [*tv* 2] *tv*) *tv*)", 1);
}

test "diff: nested binding — innermost shadows" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const user = f.env.findNs("user").?;
    const v = try f.env.intern(user, "*tv*", Value.initInteger(1), null);
    v.flags.dynamic = true;
    try f.check("(binding [*tv* 2] (binding [*tv* 3] *tv*))", 3);
}

test "diff: thrown value escaping binding caught by outer try (ADR-0071)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const user = f.env.findNs("user").?;
    const v = try f.env.intern(user, "*tv*", Value.initInteger(1), null);
    v.flags.dynamic = true;
    // The throw escapes the binding body. On the VM the binding's cleanup
    // edge (op_push_cleanup / op_reraise) pops the frame and re-fires the
    // SAME thrown value un-converted; the outer catch binds it. Both
    // backends must agree on the caught value.
    try f.check("(try (binding [*tv* 2] (throw (ex-info \"x\" {}))) (catch ExceptionInfo _ 7))", 7);
}

test "diff: catalog error escaping binding caught by outer try (ADR-0071)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const user = f.env.findNs("user").?;
    const v = try f.env.intern(user, "*tv*", Value.initInteger(1), null);
    v.flags.dynamic = true;
    // A catalog error (/ 1 0) escapes the binding. The cleanup edge
    // re-raises it un-converted (ADR-0071); the catalog→exception
    // conversion (ADR-0060) then happens at the OUTER catch handler so the
    // ArithmeticException arm matches. Parity: both backends catch → 9.
    try f.check("(try (binding [*tv* 2] (/ 1 0)) (catch ArithmeticException _ 9))", 9);
}

test "diff: binding frame restored after a caught throw (cleanup pops frame, ADR-0071)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const user = f.env.findNs("user").?;
    const v = try f.env.intern(user, "*tv*", Value.initInteger(1), null);
    v.flags.dynamic = true;
    // The exception edge runs op_pop_binding_frame before re-raising, so
    // *tv* is the root (1) again after the caught throw — same on both
    // backends (the VM cleanup edge mirrors TreeWalk's `defer popFrame`).
    try f.check("(do (try (binding [*tv* 2] (throw (ex-info \"x\" {}))) (catch ExceptionInfo _ 0)) *tv*)", 1);
}

test "diff: bare-try (no catch) cleanup re-raise caught by outer try (ADR-0071)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // The inner (try ...) has no catch clause → cleanup edge → re-raises;
    // the outer try catches. Exercises op_push_cleanup on a non-binding
    // form (try-with-zero-catches).
    try f.check("(try (try (throw (ex-info \"x\" {}))) (catch ExceptionInfo _ 5))", 5);
}

test "diff: loop*/recur countdown" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(loop* [i 0] (if (< i 3) (recur (+ i 1)) i))", 3);
}

test "diff: fn*-body recur (D-090, both backends re-enter the param frame)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // recur in fn tail position rebinds the param slots and re-enters —
    // both TreeWalk (callMethodImpl loop) and VM (compileFnMethodBody
    // recur frame) must agree.
    try f.check("((fn* [n acc] (if (< n 1) acc (recur (- n 1) (+ acc n)))) 5 0)", 15);
}

test "diff: variadic fn*-body recur rebinds the rest param" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("((fn* [a & r] (if (nil? (seq r)) a (recur (+ a (first r)) (rest r)))) 0 1 2 3 4)", 10);
}

test "diff: closure capture via let-then-fn" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("((let* [x 10] (fn* [y] (+ x y))) 5)", 15);
}

test "diff: nested if branches" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(if (if true false true) 1 2)", 2);
}

// ADR-0036 T1 retrofit: 11 cases covering the previously-untested
// non-deferred Node variants enumerated in
// private/notes/phase7-T1-survey.md §2.3. The 5 VM-DEFER sites
// (deftype_node / interop_call_node — formerly ctor_call_node / field_access_node /
// require libspec / ns refer-clojure filter) do not yet land diff
// cases — those join when the markers discharge.

test "diff: def_node" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Post-ADR-0038, `(do (def x ...) x)` resolves cleanly because
    // analyzeDef pre-registers the Var in env before the body's
    // forward references are analyzed.
    try f.check("(do (def diff-x 42) diff-x)", 42);
}

test "diff: var special form const-folds to a stable var_ref" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // D-183(a): `(var x)` const-folds to a `.constant` var_ref Node on
    // both backends; deref recovers the Var's root. Verifies the shared
    // `.constant` arm yields the same stable `*Var` under TreeWalk + VM.
    try f.check("(do (def diff-vx 7) (deref (var diff-vx)))", 7);
}

test "diff: ^meta on def target reaches Var.meta" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // D-183(b)+(c): `analyzeDef` lifts a `^{...}` def-target meta into
    // `Var.meta` at analyze time (backend-shared analysis), so `(meta
    // (var x))` reads the same map under both TreeWalk + VM.
    try f.check("(do (def ^{:a 7} diff-dm 1) (:a (meta (var diff-dm))))", 7);
}

test "diff: defn attr-map reaches Var.meta" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // D-183(d) / D-091: `expandDefn` lowers docstring + attr-map +
    // `:arglists` onto the name Form's `.meta`, so `(meta (var f))` reads
    // them identically under both backends (shared macroexpand+analyze).
    try f.check("(do (defn diff-dn {:v 9} [a] a) (:v (meta (var diff-dn))))", 9);
}
test "diff: defmacro docstring/attr-map reaches Var.meta (D-187)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // `analyzeDefmacro` (shared special form) lowers the attr-map into
    // `Var.meta` at analyze time, so `(meta (var m))` agrees on both backends.
    try f.check("(do (defmacro dmm \"d\" {:k 8} [x] x) (:k (meta (var dmm))))", 8);
}

test "diff: ^meta on collection literal lowers to with-meta (D-186)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // The analyzer rewrites `^{m} [..]` to `(with-meta [..] {m})` (shared
    // call path), so both backends attach + read the metadata identically.
    try f.check("(:foo (meta ^{:foo 7} [1 2]))", 7);
}

test "diff: empty-list literal () self-evaluates (D-188 / D-164)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // `()` lowers to a `.constant` empty-list Node (D-164: distinct from
    // nil) baked once and shared by both backends. The empty list is
    // TRUTHY (only nil / false are falsey), so `(if () 1 2)` → 1.
    try f.check("(if () 1 2)", 1);
}

// NOTE: `sequence`'s dual-backend parity is NOT diff-tested here — the
// Fixture loads primitives + macro_transforms only, NOT core.clj, so the
// `.clj` `sequence`/`map` are absent. Its TreeWalk↔VM parity is verified by
// `cljw --compare -e '(reduce + 0 (sequence (map inc) [1 2 3]))'` → OK 9
// (the real bootstrap runs both backends) + the phase14_transducers e2e.

test "diff: def_node forward ref inside (do)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // ADR-0038: forward references between def forms inside a single
    // top-level (do ...) work because analyzeDef pre-registers the
    // first def's name before the second def's value form is analyzed.
    try f.check("(do (def diff-fwd-a 10) (def diff-fwd-b diff-fwd-a) diff-fwd-b)", 10);
}

test "diff: def_node recursive defn" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // ADR-0038: recursive `defn` works because analyzeDef pre-registers
    // the function name before the body (which references itself) is
    // analyzed. Previously required `loop`/`recur` exclusively.
    try f.check("(do (defn diff-rec [n] (if (= n 0) 0 (diff-rec (- n 1)))) (diff-rec 7))", 0);
}

// Row 7.7 cycle 5: protocol round-trip (defprotocol → extend-type →
// dispatch) now lands as diff_test cases. Cycle 1's rt.trackHeap-based
// cleanup of ProtocolDescriptor / ProtocolFn / TypeDescriptorRef
// allocations (per ADR-0008 amendment 4 "Affected files") closed the
// testing.allocator leak gap that previously deferred the coverage.
// Both backends route user-fn invocation through `vtable.callFn`, so
// the four primitive paths (count / seq / conj / reduce) below
// produce byte-identical Values across TreeWalk and VM by construction.
// `extendTypeWithImpls` still leaks the old method_table slice on each
// extend (separate latent bug filed as a follow-up debt row); the test
// fixture's testing.allocator catches it, so the diff cases below use
// just one extend per type to avoid the bug.

test "diff: row 7.7 count via IPersistentCollection -count slow-path" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check(
        \\(do
        \\  (defprotocol IPersistentCollection (-count [c]))
        \\  (defrecord DiffPt [x y])
        \\  (extend-type DiffPt IPersistentCollection (-count [_] 7))
        \\  (count (->DiffPt 1 2)))
    , 7);
}

test "diff: row 7.7 seq via Seqable -seq slow-path" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check(
        \\(do
        \\  (defprotocol Seqable (-seq [c]))
        \\  (defrecord DiffPair [a b])
        \\  (extend-type DiffPair Seqable (-seq [_] '(11 22 33)))
        \\  (first (seq (->DiffPair 1 2))))
    , 11);
}

test "diff: row 7.7 conj via IPersistentCollection -cons slow-path" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check(
        \\(do
        \\  (defprotocol IPersistentCollection (-cons [c x]))
        \\  (defrecord DiffBag [contents])
        \\  (extend-type DiffBag IPersistentCollection (-cons [_ x] x))
        \\  (conj (->DiffBag '()) 13))
    , 13);
}

test "diff: row 7.7 reduce via IReduce -reduce fast-path" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check(
        \\(do
        \\  (defprotocol IReduce (-reduce [c f]))
        \\  (defrecord DiffBox [v])
        \\  (extend-type DiffBox IReduce (-reduce [_ _] 42))
        \\  (reduce + (->DiffBox 1)))
    , 42);
}

test "diff: do_node sequence" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(do 1 2 3 4 5)", 5);
}

test "diff: quote_node" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(count (quote (1 2 3 4 5)))", 5);
}

test "diff: try_node — happy path" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (+ 10 20) (catch ExceptionInfo _ 0))", 30);
}

test "diff: throw_node caught by try" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (throw (ex-info \"x\" {})) (catch ExceptionInfo _ 7))", 7);
}

test "diff: catch :keyword matches on ex-info :type (D-014b VM lowering)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // op_match_type_keyword on the VM mirrors tree_walk.catchMatches.
    try f.check("(try (throw (ex-info \"x\" {:type :foo})) (catch :foo _ 42))", 42);
}

test "diff: catch :keyword falls through on :type mismatch (D-014b)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (throw (ex-info \"x\" {:type :bar})) (catch :foo _ 1) (catch ExceptionInfo _ 2))", 2);
}

test "diff: .getData on a caught ex_info (D-198 Throwable native method)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // `.getData`/`.getMessage` resolve via the shared `.ex_info` native
    // descriptor on BOTH backends (no per-backend special-case).
    try f.check("(try (throw (ex-info \"x\" {:n 7})) (catch ExceptionInfo e (:n (.getData e))))", 7);
}

test "diff: in_ns_node switches ns" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(do (in-ns 'user) 11)", 11);
}

test "diff: require_node bare symbol" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(do (require 'clojure.core) 13)", 13);
}

test "diff: ns_node bare with refer-clojure" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(do (ns diff-ns-1 (:refer-clojure)) 17)", 17);
}

test "diff: ns_node :refer-clojure :only filter (D-098 VM op_ns_with_filter)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // The `:only [+]` whitelist refers `+` (from rt) into the new ns; the
    // subsequent `(+ 1 2)` resolves it. op_ns_with_filter on the VM mirrors
    // tree_walk::evalNs's referAllWithFilter, so both backends agree.
    try f.check("(do (ns diff-ns-only (:refer-clojure :only [+])) (+ 1 2))", 3);
}

test "diff: vector_literal_node" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(count [1 2 3 4 5 6 7])", 7);
}

test "diff: map_literal_node" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(count {:a 1 :b 2 :c 3})", 3);
}

test "diff: set_literal_node" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(count #{1 2 3 4})", 4);
}

// ADR-0037 T2: Symbol heap Value reaches formToValue identically on
// both backends via analyzeQuote (no Node variant added). This case
// actively exercises ADR-0036 D1 parity contract for the new Value
// class — both backends intern the same (ns, name) and compare via
// pointer-eq, so `(name 'sym)` round-trip returns 3 chars.
test "diff: symbol quote roundtrip + name" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(count (name 'foo))", 3);
}

// ADR-0035 D9 second amendment (T3): widened (:refer-clojure)
// semantic exercised. Tree_walk evalNs and VM op_ns_with_refer_clojure
// must both install rt + clojure.core refers into ns t3-diff, after
// which `count` resolves and `(count [10 20])` returns 2. The 99
// tail anchors the do-form's return value to an integer for the
// comparator.
test "diff: ns refer-clojure widening (post-T3 path)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(do (ns t3-diff (:refer-clojure)) (count [10 20]))", 2);
}

// ADR-0040 row 7.6 cycle 4: discharge the deftype-family +
// method-dispatch cluster. 4 diff cases (one per new opcode).

test "diff: deftype macro + interop_call_node .constructor + .instance_member field" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // ADR-0066: deftype is a macro lowering to rt/__deftype! (a primitive
    // call both backends execute), op_ctor_call + op_method_call's
    // field-first resolver. Registration is no longer a backend-specific
    // op_deftype nil-push, so the VM registers the type itself (BUG-1 fix).
    try f.check("(do (deftype DiffPoint [x y]) (.x (DiffPoint. 7 9)))", 7);
}

test "diff: deftype macro binds ->Name + applies protocol body (ADR-0066/D-087)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Both backends must agree that the positional ->Name constructor is
    // bound and the protocol impl runs (was silently dropped pre-ADR-0066).
    try f.check("(do (defprotocol IDiffP (dval [t])) (deftype DiffV [v] IDiffP (dval [_] (.v _))) (dval (->DiffV 5)))", 5);
}

test "diff: interop_call_node .constructor second field" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(do (deftype DiffPair [a b]) (.b (DiffPair. 1 33)))", 33);
}

// ADR-0050 am1 parity: both backends must agree on the unified
// instance-member resolver across (a) a native-type method, (b) a
// deftype field via the `.-name` field-only form.

test "diff: instance_member native String method (.toUpperCase)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Native receiver: field_layout == null → straight to method_table.
    // The result is a heap String, which the Phase-4 differential harness
    // compares by NaN-box bit pattern (separately allocated per backend →
    // never bit-equal). Wrap in `(= "HI" …)` so the compared Value is an
    // immediate boolean → `if` → integer; this still exercises the native
    // dispatch on both backends and additionally asserts the uppercasing.
    try f.check("(if (= \"HI\" (.toUpperCase \"hi\")) 1 0)", 1);
}

test "diff: instance_member field-only (.-name) on deftype" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // `.-b` reads the declared field directly via the field_only path.
    try f.check("(do (deftype DiffDash [a b]) (.-b (DiffDash. 1 33)))", 33);
}

// ADR-0050 am2 (D-130): `.static_method` now lowers to op_static_method_call
// on the VM, so static dispatch is differential-testable. Deterministic
// integer-returning statics only (the Phase-4 comparator is bit-pattern;
// heap/non-deterministic statics like UUID/randomUUID can't be diffed).

test "diff: static_method (Math/max) on both backends" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(Math/max 3 7)", 7);
}

test "diff: static_method (Math/abs) on both backends" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(Math/abs -5)", 5);
}

// D-076 cycle 1: `let` sequential destructuring lowers at the macro layer
// (expandLet → let* + nth), so both backends see the same let* AST and
// must agree. Integer result survives the bit-pattern comparator.

test "diff: let sequential destructure both backends" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(let [[a b] [1 2]] (+ a b))", 3);
}

test "diff: let nested destructure both backends" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(let [[[a b] c] [[1 2] 3]] (+ a b c))", 6);
}

test "diff: let associative destructure both backends" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // D-076 cycle 2: {:keys}/:or lower to get; both backends agree.
    try f.check("(let [{:keys [a b] :or {b 9}} {:a 1}] (+ a b))", 10);
}

test "diff: fn param destructure both backends" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // D-076 cycle 3: pattern params → gensym + body let; both backends agree.
    try f.check("((fn [[a b] {:keys [c]}] (+ a b c)) [1 2] {:c 3})", 6);
}

test "diff: loop destructure both backends" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // D-076 cycle 4: loop macro + destructure; recur rebinds the gensym slot.
    try f.check("(loop [[a b] [1 2]] (if (< a 3) (recur [(inc a) b]) (+ a b)))", 5);
}

test "diff: map string-key lookup both backends" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // D-151: string keys match by value (byte-eq) on both backends.
    try f.check("(get {\"a\" 1 \"b\" 2} \"b\")", 2);
}

// NOTE: comp/juxt/partition (D-134) are .clj defns over existing Nodes
// (not new analyzer Node variants), so ADR-0036 requires no differential
// case. A `((comp …) …)` diff case was tried and removed: `compare`
// bootstraps core.clj under ONE backend then swaps the vtable per run, so
// calling a BOOTSTRAP .clj closure (comp) cross-backend diverges in the
// harness (D-152) — though both backends compute it correctly in real
// whole-program runs (verified: tree-walk e2e + a VM-direct run both → 3).
// e2e phase14_comp_juxt_partition is the coverage.


// Row 7.10 cycle 2 (D-073 diff_test descriptor cleanup): the 2
// previously-deferred ADR-0040 op_method_call diff cases now land.
// Root cause of the prior DebugAllocator trip was specifically the
// anonymous reify TypeDescriptor's protocol_impls + method_table
// allocations on `rt.gpa` having no lifecycle owner (reify_anon is
// not registered in `rt.types`, so Pass 3 of `Runtime.deinit` never
// sees it). Discharge: `reifyPrim` now `rt.trackHeap`'s the descriptor
// via `freeReifyDescriptor` (`src/lang/primitive/protocol.zig`).
// Defrecord + extend-type paths route through `rt.types` registry +
// Pass 3 cleanup respectively, and never tripped the detector
// (verified empirically before the fix landed).

test "diff: row 7.10 op_method_call on defrecord (inline protocol body)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check(
        \\(do
        \\  (defprotocol IShift (shift-by [this n]))
        \\  (defrecord MCBox [v] IShift (shift-by [this n] (+ n 100)))
        \\  (.shift-by (->MCBox 1) 7))
    , 107);
}

test "diff: row 7.10 op_method_call on reify (anonymous descriptor)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check(
        \\(do
        \\  (defprotocol IShiftR (shift-by-r [this n]))
        \\  (.shift-by-r (reify IShiftR (shift-by-r [_ n] (* n 3))) 7))
    , 21);
}

// Row 7.10 cycle 3 (D-073 sub-site d discharge): `op_require_with_libspec`
// + `BytecodeChunk.libspecs` side-table. Both backends must produce
// identical post-require behaviour — exercise via clojure.set (already
// loaded at bootstrap; the `:as` / `:refer` arms are what these cases
// probe, not the resolver path). Tests use FQN after require because
// alias / refer resolution happens at analyzer time, but the require
// form's side-effect (setAlias / referOne) runs at eval time — within
// a single `do` form the analyzer cannot see alias / refer names. The
// FQN tail confirms the require itself returned nil without raising;
// the libspec arms still execute and exercise the side-table dispatch.

// Helper: pre-create a target namespace `diff-target` with an
// interned `marker = 42` so `(require '[diff-target ...])` skips the
// resolver (existing ns + mappings.count() > 0) and exercises just
// the alias / refers arms — diff_test Fixture does not run
// `bootstrap.loadCore`, so clojure.set etc. aren't available.
fn setupDiffTargetNs(f: *Fixture) !void {
    const ns = try f.env.findOrCreateNs("diff-target");
    _ = try f.env.intern(ns, "marker", Value.initInteger(42), null);
    _ = try f.env.intern(ns, "marker2", Value.initInteger(7), null);
}

// NOTE (D-234): no `for` differential cases here. `for` is a MACRO (it
// expands to letfn/lazy-seq/concat/cons — all bootstrap `.clj` closures), so
// `evaluator.compare` hits the documented bootstrap-closure harness blind
// spot (Fixture bootstraps core.clj once under one backend then swaps the
// vtable). Both backends compute `for` correctly whole-program (verified:
// VM and `-Dbackend=tree-walk` both match clj); coverage is the
// phase15_for_while e2e + clj-oracle cmps, not the diff oracle.

test "diff: op_ctor_call name index survives >255 constants (D-233)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // A single top-level form whose chunk holds >255 distinct constants
    // BEFORE the ctor-name constant. The old `(name_idx << 8)` packing
    // truncated name_idx to 8 bits, so the VM read the wrong constant and
    // raised an internal error; tree_walk was unaffected → the backends
    // diverged. The side-table fix makes both agree.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "(deftype Tb [x])\n(do ");
    var i: usize = 0;
    while (i < 270) : (i += 1) {
        var nb: [8]u8 = undefined;
        try buf.appendSlice(testing.allocator, try std.fmt.bufPrint(&nb, "{d} ", .{i}));
    }
    try buf.appendSlice(testing.allocator, "(.-x (Tb. 7)))");
    try f.check(buf.items, 7);
}

test "diff: row 7.10 op_require_with_libspec — :refer single arm" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try setupDiffTargetNs(&f);
    // Top-level form sequence (NOT wrapped in `do`) so each form's
    // analyze-then-eval pass sees the previous form's env mutation.
    // `do` would analyze both children with the do-entry env state,
    // before the require has run — the refer'd `marker` wouldn't
    // resolve. evaluator.compare's runOnce iterates `reader.read()`
    // and analyze+eval per form, which is the correct shape here.
    try f.check(
        \\(require '[diff-target :refer [marker]])
        \\marker
    , 42);
}

test "diff: row 7.10 op_require_with_libspec — :as alias arm" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try setupDiffTargetNs(&f);
    try f.check(
        \\(require '[diff-target :as dt])
        \\dt/marker
    , 42);
}

test "diff: row 7.10 op_require_with_libspec — :as + :refer combined" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try setupDiffTargetNs(&f);
    try f.check(
        \\(require '[diff-target :as dt :refer [marker]])
        \\(+ marker dt/marker)
    , 84);
}

test "diff: libspec :only whitelist arm" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try setupDiffTargetNs(&f);
    // `:only [marker]` ≡ `:refer [marker]` — marker resolves, marker2 stays
    // unreferred (the negative is asserted in the e2e via resolve→nil).
    try f.check(
        \\(require '[diff-target :only [marker]])
        \\marker
    , 42);
}

test "diff: libspec :exclude blacklist arm (:use refer-all minus)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try setupDiffTargetNs(&f);
    // `:exclude [marker2]` refers all publics except marker2; marker resolves.
    try f.check(
        \\(require '[diff-target :refer :all :exclude [marker2]])
        \\marker
    , 42);
}

// Row 7.11 cycle 3 (D-077 close): catch-class hierarchy walk via
// `runtime/error/host_class.zig::matches`. Both backends share the
// predicate (tree_walk.catchMatches + vm.matchExceptionClass both
// 1-line delegate to `host_class.matches`); these cases lock the
// JVM-compatible parent-chain semantics. Analyzer-time
// `catch_class_unknown` raise also covered here via a negative
// expectation (cf. e2e for the user-facing diagnostic).

test "diff: row 7.11 catch RuntimeException matches ex-info (parent walk)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (throw (ex-info \"boom\" {})) (catch RuntimeException e 1))", 1);
}

test "diff: row 7.11 catch Throwable matches everything" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (throw (ex-info \"x\" {})) (catch Throwable e 2))", 2);
}

test "diff: row 7.11 catch Exception matches via RuntimeException" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (throw (ex-info \"x\" {})) (catch Exception e 3))", 3);
}

test "diff: row 7.11 catch sibling skipped, specific arm fires" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check(
        \\(try (throw (ex-info "x" {}))
        \\  (catch IOException e 10)
        \\  (catch ExceptionInfo e 4))
    , 4);
}

test "diff: row 7.11 catch FQCN java.lang.RuntimeException normalises" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (throw (ex-info \"x\" {})) (catch java.lang.RuntimeException e 5))", 5);
}

// ADR-0060: internal runtime errors (error_catalog) are catchable via a
// synthesized class-name-bearing ex_info. Both backends synthesize at
// their error-propagation point and route through the SAME catch-match
// loop, so the class hierarchy + no-match re-raise must agree.

test "diff: ADR-0060 catch ArithmeticException on (/ 1 0)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (/ 1 0) (catch ArithmeticException e 1))", 1);
}

test "diff: ADR-0060 catch Exception on (/ 1 0) via RuntimeException" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (/ 1 0) (catch Exception e 2))", 2);
}

test "diff: ADR-0060 catch IndexOutOfBoundsException on nth out-of-range" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(try (nth [1] 5) (catch IndexOutOfBoundsException e 4))", 4);
}

test "diff: ADR-0060 internal error no-match inner re-raises to outer" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check(
        \\(try (try (/ 1 0) (catch clojure.lang.ExceptionInfo e 0))
        \\  (catch ArithmeticException e 6))
    , 6);
}

// Row 7.12 cycle 1 (D-078 prep): `instance?` macro + `__instance?`
// primitive + `runtime/class_name.zig` registry. Both backends share
// the macro_dispatch lowering and the Layer-2 primitive, so dispatch
// shape is identical by construction. Tests lock the 4 dispatch
// arms: native exact-tag / Number interface / IFn interface / Throwable
// hierarchy (false on non-throwable).

test "diff: row 7.12 instance? native exact tag" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(if (instance? String \"abc\") 1 0)", 1);
}

test "diff: row 7.12 instance? Number matches integer + float" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(+ (if (instance? Number 42) 1 0) (if (instance? Number 3.14) 2 0))", 3);
}

test "diff: row 7.12 instance? IFn matches fn_val" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(if (instance? IFn (fn* [x] x)) 7 0)", 7);
}

test "diff: row 7.12 instance? Throwable false on non-throwable" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(+ (if (instance? Throwable nil) 100 0) (if (instance? Throwable 42) 200 0))", 0);
}

// ADR-0042 row 7.9: `apply` variadic-callee bind-direct gate. Both
// backends share `tree_walk.callFunction` (vm.zig:573 wires
// `treeWalkCall` into the VM vtable), so the gate fires identically
// on both. Three positive cases (list / cons / leading + list tail)
// + one negative case (vector still spreads to the rest slot).

test "diff: row 7.9 apply variadic bind-direct (list tail, no leading)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(apply (fn* [& xs] (count xs)) '(1 2 3 4 5))", 5);
}

test "diff: row 7.9 apply variadic bind-direct (list tail, with leading)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(apply (fn* [a b & xs] (count xs)) 10 20 '(3 4 5))", 3);
}

test "diff: row 7.9 apply variadic bind-direct (identity through rest)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(apply (fn* [& xs] (first xs)) '(99 100 101))", 99);
}

test "diff: row 7.9 apply variadic with vector tail (spread still works)" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Vector tail hits the eager-spread fallback (vectors are NOT in
    // the bind-direct gate's seq-tag set); xs binds to (1 2 3 4 5),
    // count returns 5. Locks the negative case so a future widening
    // of the gate to include vector tags would fail this case
    // (and need an explicit ADR amendment).
    try f.check("(apply (fn* [& xs] (count xs)) [1 2 3 4 5])", 5);
}

// Phase 13 row 13.1: STM `ref` / `deref` (read-only path, ADR-0010
// amendment 3). Both backends must agree on the heap Ref construct +
// the deref read. The second case exercises a Ref holding a heap
// Value (vector) so the GC trace path is crossed on both backends.

test "diff: ref deref round-trip" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(deref (ref 5))", 5);
}

test "diff: ref holds heap value, deref then count" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(count (deref (ref [1 2 3])))", 3);
}

// Phase 13 row 13.3 (ADR-0047): VM peephole optimizer. Both backends
// must agree on (do ...) forms whose non-final pure-push forms get
// elided by peephole (`op_const|op_load_local + op_pop` pair), and on
// branch-bearing forms where the elision happens between a jump and
// its target (peephole IP-remap must re-resolve the offset).

test "diff: peephole — do with pure-push non-final form" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // (do 1 2 3) compiles to `op_const 1; op_pop; op_const 2; op_pop;
    // op_const 3; op_ret`. Peephole removes both push-pop pairs.
    try f.check("(do 1 2 3)", 3);
}

test "diff: peephole — if with pure-push elision inside both branches" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Both branches contain a (do …) whose non-final pure push is
    // elided; the if's op_jump must be re-resolved after compaction.
    try f.check("(if true (do 9 7) (do 8 6))", 7);
}

// ADR-0056 Cycle 0 — the VM-dispatch knot. A DESERIALIZED (AOT) fn carries
// a sentinel `body` + bytecode only, so calling it MUST route through the
// vtable's `evalChunk` slot. After Cycle 0, `driver.installVTable` wires
// `evalChunk` into the tree_walk vtable too, so a tree_walk-default runtime
// (the production runner) can host AOT-restored bootstrap fns. A
// freshly-compiled fn would mask this (it retains a real AST body), so the
// test round-trips through the serializer to force the sentinel-body form.
test "aot: deserialized bytecode fn dispatches via tree_walk vtable evalChunk" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    driver.installVTable(&f.rt);

    const arena = f.arena.allocator();
    var reader = Reader.init(arena, "(fn* [x] (+ x 1))");
    const form = (try reader.read()).?;
    const node = try analyze(arena, &f.rt, &f.env, null, form, &f.table);
    const chunk = try vm_compiler.compile(&f.rt, arena, node);

    const bytes = try serialize.serializeChunk(testing.allocator, chunk);
    defer testing.allocator.free(bytes);
    const chunk2 = try serialize.deserializeChunk(arena, &f.rt, &f.env, bytes);

    var fn_val: Value = .nil_val;
    for (chunk2.constants) |c| {
        if (c.tag() == .fn_val) {
            fn_val = c;
            break;
        }
    }
    try testing.expect(fn_val.tag() == .fn_val);

    const result = try tree_walk.callFunction(&f.rt, &f.env, fn_val, &.{Value.initInteger(5)}, .{});
    try testing.expectEqual(@as(i64, 6), result.asInteger());
}
