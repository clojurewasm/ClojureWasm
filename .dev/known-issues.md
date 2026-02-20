# Known Issues & Technical Debt

> Master list of all known bugs, workarounds, stubs, and design concerns.
> Ordered by resolution priority. Referenced from roadmap.md and memo.md.

## Priority Guide

- **P0 (Block)**: User-facing bugs. Fix before any new feature work.
- **P1 (High)**: Development infrastructure. Fix to prevent future regressions.
- **P2 (Medium)**: Correctness gaps. Fix during related phase work.
- **P3 (Low)**: Design debt. Address in dedicated cleanup phases.

---

## P0: User-Facing Bugs

### ~~I-001: `cljw test` state pollution across test files~~ RESOLVED

**Resolution**: Fresh `Env` per test file in `handleTestCommand` (88C.1).
Each file gets: `shutdownGlobalPool()` → `resetLoadedLibs()` → `Env.init()` → `bootstrapFromCache()`.
Also fixed missing `(ns ...)` forms in `clojure_walk.clj`, `sci/core_test.clj`, `sci/hierarchies_test.clj`
that relied on leaked state.

### ~~I-002: `bit-shift-left/right` panics on shift amounts outside 0-63~~ RESOLVED

**Resolution**: Already fixed — code uses `@truncate` (not `@intCast`), which
naturally applies `& 0x3f` masking. Verified: `(bit-shift-left 1 64)` → 1, no panic.

### ~~I-003: `char` returns char type, not string~~ RESOLVED

**Resolution**: CW behavior was correct (JVM: `(char 65)` → `\A`, not `"A"`).
Test expectations in `numbers.clj` were wrong — fixed to compare with char literals.
Also fixed `(char \A)` → identity (was erroring "Cannot cast char to char").

---

## P1: Development Infrastructure

### ~~I-010: No unified "run all tests" command~~ RESOLVED

**Resolution**: Created `test/run_all.sh` — runs all 5 suites (zig test, release build,
cljw test, e2e, deps e2e) with unified summary. CLAUDE.md commit gate updated.

### I-011: `finally` blocks silently swallow exceptions

**Symptom**: In TreeWalk evaluator, `finally` block execution uses `catch {}`
which discards exceptions thrown inside `finally`. JVM Clojure propagates
finally-block exceptions (replacing the original exception).

**Fix**: Store finally-block exception and propagate it (JVM semantics).

**Files**: `src/evaluator/tree_walk.zig:1398,1415,1422,1428,1434`

### I-012: Watch/validator callback errors silently swallowed

**Symptom**: `add-watch` and `set-validator!` callback errors are caught with
`catch {}`. JVM throws the exception to the caller.

**Fix**: Propagate callback errors. For watches, JVM prints to `*err*` but
doesn't throw. For validators, JVM throws.

**Files**: `src/builtins/atom.zig:355`, `src/runtime/stm.zig:388`,
`src/runtime/thread_pool.zig:333`

### I-013: Bootstrap namespace refer errors silently swallowed

**Symptom**: ~80 instances of `ns.refer(...) catch {}` in bootstrap.zig.
If a refer fails (e.g., name collision), it's silently ignored.

**Fix**: Log a warning on refer failure (at minimum). These are bootstrap-time
only so a panic is too aggressive, but silent failure hides real issues.

**Files**: `src/runtime/bootstrap.zig` (throughout load* functions)

---

## P2: Correctness Gaps (fix during related phase work)

### I-020: syntax-quote metadata propagation (macros.clj 8F)

**Symptom**: `^:foo (bar)` metadata not preserved through syntax-quote expansion.
Affects macro authors who use metadata hints.

**Fix**: Audit syntax-quote in `src/reader/reader.zig` or macro expansion in
`src/builtins/macro.zig` — ensure metadata on forms is carried through.

**Phase**: Fix during Phase B (macro migration touches this code)

### I-021: CollFold protocol not implemented (reducers.clj 11F)

**Symptom**: `r/fold` falls back to sequential reduce. No parallel folding.
ForkJoin stubs (`fjtask/fjfork/fjjoin`) are all no-ops.

**Fix**: Implement a thread-pool-based fold (CW has thread_pool.zig).
Replace ForkJoin stubs with actual parallel execution.

**Phase**: Phase B.13 (reducers → Zig) or Phase 89 (Performance)

### I-022: spec.alpha largely unimplemented (spec.clj 25E)

**Symptom**: Core spec ops work (`valid?`, `conform`, `def`, `and`, `or`, `keys`)
but `fdef`, `instrument`, generators, and most complex specs fail.

**Fix**: Complete spec implementation during Phase B.15 (spec → Zig).

**Phase**: Phase B.15

### I-023: pointer→i64 @intCast in interop classes

**Symptom**: State pointers stored as `Value.initInteger(@intCast(@intFromPtr(state)))`.
On 64-bit systems, high-bit pointers would panic.

**Fix**: Use `@bitCast` instead of `@intCast` for pointer-to-integer conversion.

**Files**: `src/interop/classes/string_writer.zig:63`,
`pushback_reader.zig:129`, `buffered_writer.zig:93`, `string_builder.zig:80`

### I-024: wasm bridge double @intCast truncation

**Symptom**: `@intCast(@as(i32, @intCast(val.asInteger())))` panics if value
exceeds i32 range.

**Fix**: Add range check or use saturating cast.

**Files**: `src/wasm/types.zig:297,395`

---

## P3: Design Debt (dedicated cleanup phases)

### I-030: ~170 UPSTREAM-DIFF markers in src/clj/

**Symptom**: Each marker represents a behavioral deviation from JVM Clojure.
Categories:
- Java exception → ex-info rewrites (zip, spec, test): ~30
- Java stream/IO → CW native (io, main, pprint): ~40
- Java type system → cond/predicate dispatch (data, walk): ~15
- ForkJoin → sequential (reducers): ~12
- Java class interop → stubs (server, repl.deps): ~10
- pprint Writer proxy → atom-based (pprint): ~30
- spec JVM-specific → simplified (spec): ~30

**Resolution**: Most will be resolved organically during Phase B (each .clj → Zig).
Markers in F94 (checklist.md) track the "R" category that requires infrastructure.

### I-031: 27 stub vars in vars.yaml

**Symptom**: Vars marked `done` in vars.yaml but are actually stubs (return nil
or throw). Examples: `*err*`, `*in*`, `*out*`, `start-server`, `add-lib`.

**Fix**: Either implement properly or change status to `skip` with clear note.
`*err*`/`*in*`/`*out*` need CW I/O stream design (Phase 89 or dedicated phase).

### I-032: Stub namespaces (server, repl.deps)

**Symptom**: `clojure.core.server` and `clojure.repl.deps` throw on every call.

**Resolution**: server requires Zig networking (Phase 93 LSP or dedicated).
repl.deps requires runtime deps loading (low priority for CW).

### I-033: Zig macro transforms limited to clojure.core

**Symptom**: Current transform system only handles `clojure.core` macros.
Non-core `.clj` macros (test/do-template, main/with-bindings) need defmacro.
Phase B must either:
(a) Implement namespace-scoped transforms, or
(b) Convert defmacros to Zig builtin functions with `setMacro(true)`

**Resolution**: Design decision needed at Phase B start.

### I-034: deferred cache smp_allocator workaround

**Symptom**: `initDeferredCacheState` copies strings to `smp_allocator` to
prevent GC collection. This is a workaround for the real issue (GC doesn't
know about deferred cache roots).

**Resolution**: Will be eliminated in Phase C (bootstrap pipeline removal).

---

## Resolution Timeline

| Issue | When to Fix | Phase |
|-------|------------|-------|
| I-001 | ~~**Now**~~ RESOLVED | 88C.1 |
| I-002 | ~~**Now**~~ RESOLVED (already fixed) | pre-88C |
| I-003 | ~~**Now**~~ RESOLVED | 88C.3 |
| I-010 | ~~**Now**~~ RESOLVED | 88C.4 |
| I-011 | During Phase B | B (TreeWalk touches) |
| I-012 | During Phase B | B (atom/stm builtins) |
| I-013 | During Phase C | C (bootstrap simplification) |
| I-020 | During Phase B | B (macro code touches) |
| I-021 | Phase B.13 or 89 | B.13 / 89 |
| I-022 | Phase B.15 | B.15 |
| I-023 | During Phase B | B (interop touches) |
| I-024 | During Phase B | B (wasm bridge review) |
| I-030 | Phase B (organically) | B |
| I-031 | Phase B + Phase 89 | B / 89 |
| I-032 | Phase 93 / never | 93 |
| I-033 | Phase B start | B.0 (design decision) |
| I-034 | Phase C | C |
