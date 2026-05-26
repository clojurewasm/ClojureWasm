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

test "diff: fn* immediate invocation" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("((fn* [x y] (+ x y)) 3 4)", 7);
}

test "diff: loop*/recur countdown" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(loop* [i 0] (if (< i 3) (recur (+ i 1)) i))", 3);
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
// (deftype_node / ctor_call_node / field_access_node /
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

test "diff: deftype_node + ctor_call_node + field_access_node" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Combined exercise of op_deftype + op_ctor_call + op_field_access.
    try f.check("(do (deftype DiffPoint [x y]) (.x (DiffPoint. 7 9)))", 7);
}

test "diff: ctor_call_node second field" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    try f.check("(do (deftype DiffPair [a b]) (.b (DiffPair. 1 33)))", 33);
}


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
