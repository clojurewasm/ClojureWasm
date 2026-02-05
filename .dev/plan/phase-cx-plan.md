# Phase CX: Known Issue Resolution (inserted between C12 and C13)

Inserted phase to resolve actionable F## items before continuing test porting.
These items are already understood and implementable with current infrastructure.

**When**: After C12 (sequences.clj), before C13 (clojure_walk.clj)
**Why**: Fixing known issues now prevents cascading workarounds during C13-C20.
**Rule**: Same as Phase C — root-cause fixes, no workarounds, both backends.

## Key References

Read these files before starting implementation:

| Reference                              | Purpose                                     |
|----------------------------------------|---------------------------------------------|
| `.dev/checklist.md`                    | F## item definitions and triggers           |
| `.dev/status/vars.yaml`               | Var status tracking (update after each fix) |
| `.claude/rules/test-porting.md`       | Test change rules (CLJW markers etc.)       |
| `.claude/references/interop-patterns.md` | Java interop translation patterns        |
| `.claude/references/impl-tiers.md`    | Implementation tier guide                   |
| `src/common/analyzer/analyzer.zig`    | Analyzer (F68, F70-74, F81, F87, F89)      |
| `src/common/value.zig`                | Value types (F91 delay variant)             |
| `src/common/builtin/predicates.zig`   | Predicate builtins (F86, F91)               |
| `src/common/builtin/multimethods.zig` | Multimethod builtins (F82, F83)             |
| `src/clj/clojure/core.clj`           | Core macros/fns (F82, F91, F94)             |

Beta reference for delay type:
- `ClojureWasmBeta/src/lib/core/concurrency.zig` (Delay struct, force, realized?)
- `ClojureWasmBeta/src/base/value.zig` (delay_val variant)

Beta reference for hierarchy/multimethod:
- `ClojureWasmBeta/src/lib/core/interop.zig` (derive, isa?, prefer_table)

## Task Queue

### CX1: Remove F51 + Fix F24 (housekeeping)

**Scope**: checklist.md + vars.yaml corrections.

1. Remove F51 from checklist.md (shuffle is implemented and tested)
2. Fix vars.yaml: `await1` status `done` → `todo` (implementation missing)
3. Fix bootstrap.zig test for `drop` if needed (lazy-seq return type)
4. Verify `zig build test` passes

**Files**: `.dev/checklist.md`, `.dev/status/vars.yaml`, `src/common/bootstrap.zig`

### CX2: bound? takes var_ref (F86)

**Scope**: Change `bound?` to accept var_ref (`#'x`) instead of symbol.

1. Modify `boundPred()` in `src/common/builtin/predicates.zig`
   - Accept `.var_ref` type instead of `.symbol`
   - Check if var has a binding root
2. Update `defonce` macro in `src/clj/clojure/core.clj`
   - Change from `(bound? 'name)` to `(bound? #'name)` or equivalent
3. Both backends test

**Files**: `src/common/builtin/predicates.zig`, `src/clj/clojure/core.clj`

### CX3: Math/System syntax routing (F89)

**Scope**: Route `(Math/abs x)` → `(__abs x)` etc. in the analyzer.

1. In `src/common/analyzer/analyzer.zig`, when analyzing a call where the
   function position is a symbol with namespace "Math" or "System":
   - Map `Math/abs` → `__abs`, `Math/sqrt` → `__sqrt`, etc.
   - Map `System/getenv` → `__getenv`, `System/exit` → `__exit`, etc.
   - Map `System/nanoTime` → `__nano-time`, `System/currentTimeMillis` → `__current-time-millis`
2. Add a static lookup table for known Java→Zig mappings
3. Both backends test with `(Math/abs -5)`, `(System/getenv "HOME")`

**Files**: `src/common/analyzer/analyzer.zig`
**Reference**: `.claude/references/interop-patterns.md`

### CX4: delay proper Value type (F91)

**Scope**: Replace map-based delay with dedicated Value variant.

1. Add `Delay` struct to `src/common/value.zig`:
   ```zig
   pub const Delay = struct {
       fn_val: ?Value,  // thunk (null after realization)
       cached: ?Value,  // cached result
       realized: bool,
   };
   ```
2. Add `delay: *Delay` variant to Value union
3. Add `__delay-create` builtin (takes fn, returns Delay value)
4. Update `force` / `deref` to handle `.delay` variant
5. Update `delay?` and `realized?` predicates
6. Update `typeFn` to return `:delay`
7. Update `formatPrStr` for delay printing
8. Rewrite `delay` macro in core.clj to use `__delay-create`
9. Verify `test/upstream/clojure/test_clojure/delays.clj` still passes (both backends)

**Files**: `src/common/value.zig`, `src/common/builtin/predicates.zig`,
  `src/common/builtin/atom.zig` (or new concurrency.zig),
  `src/clj/clojure/core.clj`
**Beta ref**: `ClojureWasmBeta/src/base/value.zig`, `ClojureWasmBeta/src/lib/core/concurrency.zig`

### CX5: {:as x} seq-to-map coercion (F68)

**Scope**: Map destructuring `:as` binding should coerce seqs to maps.

1. In `expandMapPattern()` in `src/common/analyzer/analyzer.zig`:
   - When binding `:as`, apply seq→map coercion before binding
   - Empty seq `()` → empty map `{}`
   - Seq with elements → convert to map (via `apply hash-map`)
   - Non-seq → pass through unchanged
2. This matches JVM `destructure` function behavior (PersistentArrayMap/createAsIfByAssoc)
3. Test: `(let [{:as x} ()] x)` should return `{}`

**Files**: `src/common/analyzer/analyzer.zig`
**Upstream ref**: `/Users/shota.508/Documents/OSS/clojure/src/clj/clojure/core.clj` lines 4472-4479

### CX6: Namespaced destructuring (F70-F74)

**Scope**: Support all 5 namespaced destructuring variants.

All changes in `expandMapPattern()` in `src/common/analyzer/analyzer.zig`:

1. **F70**: `{:keys [:a/b]}` — keyword with namespace in :keys vector
   - Extract ns from keyword, use `:a/b` as map lookup key, bind to `b`
2. **F71**: `{:keys [a/b]}` — symbol with namespace in :keys vector
   - Extract ns from symbol, use `:a/b` as map lookup key, bind to `b`
3. **F72**: `{:syms [a/b]}` — symbol with namespace in :syms vector
   - Extract ns from symbol, use `'a/b` as map lookup key, bind to `b`
4. **F73**: `{:a/keys [b]}` — namespace-qualified :keys keyword
   - Extract ns "a" from `:a/keys` keyword itself
   - For each `b` in vector, use `:a/b` as map lookup key
5. **F74**: `{:a/syms [b]}` — namespace-qualified :syms keyword
   - Extract ns "a" from `:a/syms` keyword itself
   - For each `b` in vector, use `'a/b` as map lookup key

Key change: `makeGetKeywordCall()` and `makeGetSymbolCall()` must accept
namespace parameter (currently always null).

**Files**: `src/common/analyzer/analyzer.zig`
**Upstream ref**: `/Users/shota.508/Documents/OSS/clojure/src/clj/clojure/core.clj` lines 4485-4489

### CX7: ::foo auto-resolved keyword (F81)

**Scope**: Support `::foo` resolving to `:current-ns/foo`.

Minimal approach — resolve in Analyzer, not Reader:

1. Reader already strips double-colon but loses the "auto-resolve" signal
2. Option A: Reader marks auto-resolved keywords (add flag to Form)
3. Option B: Reader passes `::foo` as keyword with special ns marker (e.g. `__auto__`)
4. Analyzer resolves `__auto__/foo` → `:current-ns/foo` using `env.current_ns`
5. `::alias/foo` support: resolve alias via namespace alias table

**Files**: `src/common/reader/reader.zig`, `src/common/analyzer/analyzer.zig`
**Note**: `::alias/foo` requires namespace alias infrastructure (may be deferred)

### CX8: Hierarchy system (F82 + F83)

**Scope**: Full hierarchy system + multimethod preference.

Part A — Hierarchy functions:

1. Upgrade `isa?` in core.clj from `(= child parent)` to hierarchy-aware
2. Implement `derive` (2-arity: global, 3-arity: local hierarchy)
3. Implement `underive` (2-arity + 3-arity)
4. Implement `parents`, `ancestors`, `descendants`
5. Add `*global-hierarchy*` dynamic var (or use existing `make-hierarchy` result)
6. All pure Clojure in core.clj (no Zig changes needed for hierarchy itself)

Part B — Multimethod preference:

1. Add `prefer_table` field to `MultiFn` struct in `value.zig`
2. Implement `prefer-method` builtin in `multimethods.zig`
3. Implement `prefers` builtin in `multimethods.zig`
4. Update multimethod dispatch to use `isa?` + `prefer_table` for resolution

**Files**: `src/clj/clojure/core.clj`, `src/common/value.zig`,
  `src/common/builtin/multimethods.zig`
**Beta ref**: `ClojureWasmBeta/src/lib/core/interop.zig`

### CX9: #'var inside deftest body (F87)

**Scope**: Allow `#'x` to work for vars defined within deftest.

Problem: Analyzer resolves `#'x` at analysis time, but `(def x ...)` inside
deftest hasn't been executed yet.

Approach: Make var-quote resolution lazy for unresolved vars:
1. If `#'x` can't be resolved at analysis time, emit a runtime var-lookup node
2. At runtime, look up the var by name in the current namespace
3. This allows `(deftest foo (def x 1) (is (bound? #'x)))` to work

**Files**: `src/common/analyzer/analyzer.zig`
**Note**: This is the most complex CX task; may require careful testing

### CX10: UPSTREAM-DIFF quick fixes (F94 partial)

**Scope**: Fix immediately-resolvable UPSTREAM-DIFF items.

These vars can be replaced with upstream-verbatim implementations:

1. `assert` — change from variadic to multi-arity defmacro
2. `dotimes` — use `unchecked-inc` instead of `+`
3. `if-let` / `when-let` / `when-some` / `if-some` — add assert-args or use upstream
4. `cond` — add even-forms check
5. `dedupe` — use `sequence` instead of `into`
6. `halt-when` — `:__halt` → `::halt` (depends on CX7 for `::` support)

For each: read upstream source → copy → test → update vars.yaml note.

**Files**: `src/clj/clojure/core.clj`, `.dev/status/vars.yaml`
**Upstream ref**: `/Users/shota.508/Documents/OSS/clojure/src/clj/clojure/core.clj`

### CX11: Deferred — find-keyword (F80)

**Status**: Deferred to later. Requires keyword intern table infrastructure
that touches Reader → Analyzer → Runtime pipeline. Not blocking C13-C20.

## Completion Criteria

- All resolved F## items removed from `.dev/checklist.md`
- `.dev/status/vars.yaml` updated for any new/changed vars
- `zig build test` passes
- Both VM and TreeWalk backends verified
- memo.md updated to resume Phase C at C13
