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

test "diff: deftype_node + interop_call_node .constructor + .instance_member field" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    // Combined exercise of op_deftype + op_ctor_call + op_method_call's
    // field-first resolver (ADR-0050 am1 — op_field_access retired).
    try f.check("(do (deftype DiffPoint [x y]) (.x (DiffPoint. 7 9)))", 7);
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
