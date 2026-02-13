# Next Phases Plan (Phase 70-73)

> Post-v0.2.0 development plan.
> Focus: spec.alpha, library compatibility, optimization, GC improvement.
> Always guard non-functional baselines (`.dev/baselines.md`).

## Guiding Principles

1. **Non-functional regression is a hard block** — binary ≤ 4.0MB, startup ≤ 5ms,
   RSS ≤ 12MB, bench ≤ 1.2x baseline. No exceptions.
2. **Fix root causes, not workarounds.** Library compat failures = implementation issues.
3. **Out of scope** (for now): x86_64 JIT, Windows, LSP, Homebrew publication,
   Wasm module deps, spec.test.alpha (stest/instrument).

---

## Phase 70: spec.alpha (87 vars, ~2000 LOC upstream)

Upstream: `~/Documents/OSS/spec.alpha/src/main/clojure/clojure/spec/alpha.clj`
Upstream tests: `~/Documents/OSS/spec.alpha/src/test/clojure/clojure/test_clojure/spec.clj` (312 lines)

### Analysis Summary

| Category | Vars | Description |
|----------|------|-------------|
| A: Pure Clojure | ~48 | Macros, protocol dispatch, data ops — port directly |
| B: Light Java interop | ~23 | instance?, UUID, Integer/MAX_VALUE — Zig equivalents |
| C: Heavy Java interop | ~7 | MultiFn reflection, fn-sym, RT internals — adaptation |
| D: gen/test.check dependent | ~9 | Stub initially (gen*, exercise, etc.) |

### Key Java→Zig Adaptations Needed

| Java Construct | Usage Count | Zig Equivalent |
|----------------|-------------|----------------|
| `java.util.UUID/randomUUID` | 5 | `std.crypto.random` → format as UUID string |
| `Integer/MAX_VALUE` | 2 | `std.math.maxInt(i64)` |
| `clojure.lang.IObj` check | 2 | `meta` protocol check (already have IMeta) |
| `Double/isInfinite` / `isNaN` | 1 | `std.math.isInf` / `std.math.isNan` |
| `clojure.lang.MultiFn` reflection | 1 | Access defmulti internals via builtin |
| `clojure.lang.Compiler/demunge` | 1 | Function metadata `:name` key |
| `clojure.lang.RT/checkSpecAsserts` | 3 | Global dynamic var `*check-asserts*` |
| `System/getProperty` | 1 | `System/getenv` (already implemented) |

### Sub-phases

#### 70.1: Infrastructure + Protocols

- [ ] UUID generation builtin (`random-uuid` — already in vars.yaml as done?)
- [ ] Verify `Integer/MAX_VALUE` equivalent works
- [ ] `Spec` protocol (conform*, unform*, explain*, gen*, with-gen*, describe*)
- [ ] `Specize` protocol + extend to Keyword, Symbol, Set, default
- [ ] `fn-sym` adaptation (use fn metadata `:name` instead of class demangling)
- [ ] Internal helpers: `spec-name`, `reg-resolve`, `reg-resolve!`, `->sym`
- [ ] Registry atom + `def-impl`, `get-spec`, `registry`
- [ ] `spec?`, `regex?`, `invalid?`

#### 70.2: Core Specs + Macros

- [ ] `spec-impl` (reify Spec — the workhorse)
- [ ] `s/def` macro
- [ ] `s/valid?`, `s/conform`, `s/unform`
- [ ] `s/explain`, `s/explain-data`, `s/explain-str`, `s/explain-out`
- [ ] `s/and`, `and-spec-impl`
- [ ] `s/or`, `or-spec-impl`
- [ ] `s/keys`, `keys*`, `map-spec-impl`
- [ ] `s/merge`, `merge-spec-impl`
- [ ] `s/every`, `every-impl`, `s/every-kv`
- [ ] `s/coll-of`, `s/map-of`
- [ ] `s/tuple`, `tuple-impl`
- [ ] `s/nilable`, `nilable-impl`
- [ ] `s/conformer`, `s/nonconforming`
- [ ] `s/with-gen`, `s/form`, `s/describe`

#### 70.3: Regex Ops + Advanced

- [ ] `s/cat`, `cat-impl`
- [ ] `s/alt`, `alt-impl`
- [ ] `s/*`, `s/+`, `s/?`
- [ ] `s/&`, `amp-impl`
- [ ] `rep-impl`, `rep+impl`, `maybe-impl`
- [ ] `regex-spec-impl`
- [ ] `s/fspec`, `fspec-impl`
- [ ] `s/fdef`
- [ ] `s/multi-spec`, `multi-spec-impl` (MultiFn adaptation)
- [ ] `s/int-in`, `s/int-in-range?`
- [ ] `s/inst-in`, `s/inst-in-range?`
- [ ] `s/double-in`
- [ ] `s/assert`, `s/assert*`, `s/check-asserts`, `s/check-asserts?`
- [ ] Dynamic vars: `*compile-asserts*`, `*recursion-limit*`, `*fspec-iterations*`,
      `*coll-check-limit*`, `*coll-error-limit*`, `*explain-out*`

#### 70.4: gen stubs + spec.gen.alpha shell

- [ ] `gen*` method in all reify impls → stub returning nil or error
- [ ] `s/gen` → calls gen* (returns error if no test.check)
- [ ] `s/exercise`, `s/exercise-fn` → error without test.check
- [ ] `clojure.spec.gen.alpha` namespace: 54 vars — stub most, implement
      `boolean`, `delay`, `not-empty` (already done per vars.yaml)
- [ ] Port upstream spec.clj tests (312 lines, skip gen-dependent tests)

### Implementation Notes

- spec.alpha is almost entirely `core.clj`-level (Tier 2). Only UUID gen and
  a few builtins need Zig (Tier 1).
- `reify` in spec.alpha creates anonymous protocol implementations. CW already
  has `reify` for protocols — verify it works for Spec protocol.
- Regex ops (cat, alt, *, +, ?) use an internal tagged-map representation
  (`::op`, `::forms`, `::preds`). This is pure Clojure data — no Java needed.
- **Binary size risk**: Adding ~2000 LOC of Clojure source to bootstrap.
  Monitor binary size after each sub-phase.

---

## Phase 71: Pure Clojure Library Compatibility Testing

### Approach

1. Clone library → `~/Documents/OSS/<lib>/`
2. Point CW at its `src/` via deps.edn or `-A` flag
3. Run its test suite via `cljw test`
4. Categorize failures:
   - **Root cause fix**: Missing/buggy CW feature → implement
   - **Document**: JVM-only feature, out of scope → record in `.dev/compat-results.md`
5. Goal: each library either passes tests or has documented exceptions

### Library Candidates (5)

| # | Library | Repo | LOC (src) | Why |
|---|---------|------|-----------|-----|
| 1 | **medley** | weavejester/medley | ~400 | Utility fns, pure Clojure, no deps. Best first test. |
| 2 | **hiccup** | weavejester/hiccup | ~300 | HTML gen, pure Clojure, widely used. |
| 3 | **clojure.data.json** | clojure/data.json | ~500 | JSON, pure Clojure, no spec dep. |
| 4 | **honeysql** | seancorfield/honeysql | ~2000 | SQL DSL, uses spec lightly. Tests spec.alpha. |
| 5 | **camel-snake-kebab** | clj-commons/camel-snake-kebab | ~200 | String case conversion, pure Clojure. |

### Sub-tasks

#### 71.1: medley

- [ ] Clone, run tests, fix issues
- [ ] Record results in `.dev/compat-results.md`

#### 71.2: hiccup

- [ ] Clone, run tests, fix issues
- [ ] Record results

#### 71.3: clojure.data.json

- [ ] Clone, run tests, fix issues
- [ ] Record results

#### 71.4: honeysql (depends on 70.x for spec)

- [ ] Clone, run tests, fix issues
- [ ] Record results

#### 71.5: camel-snake-kebab

- [ ] Clone, run tests, fix issues
- [ ] Record results

### Expected Blockers

- Missing spec.alpha → honeysql (Phase 70 prerequisite)
- Java Class references in test code → skip those tests
- `clojure.test/use-fixtures` behavior differences
- Namespace loading edge cases (require ordering, circular deps)
- Missing vars in clojure.string or clojure.set (check coverage)

---

## Phase 72: Optimization + GC Assessment

### Goal

Profile real workloads and determine if GC is the bottleneck before
committing to generational GC (Phase 73).

### Approach

1. **Profile existing benchmarks** — identify where time is spent:
   - GC (mark/sweep/free-pool)?
   - Collection allocation (persistent DS overhead)?
   - Dispatch overhead (protocol/multimethod)?
   - Bootstrap (core.clj loading)?

2. **Profile library test suites** (from Phase 71) as real workloads

3. **Measure GC metrics**:
   - Collection count per benchmark
   - Average sweep time
   - Live object count at peak
   - Free-pool hit rate

4. **Optimization targets** (from checklist.md):
   - F102: chunked map/filter processing
   - F103: escape analysis (local scope skip GC)
   - General: reduce allocation rate in hot paths

5. **Decision gate**: If GC sweep time < 10% of total runtime in benchmarks,
   generational GC is not the priority. Focus on other optimizations instead.

### Sub-tasks

#### 72.1: Profiling infrastructure

- [ ] Add GC timing instrumentation (behind comptime flag)
- [ ] Measure: alloc count, sweep count, sweep time, live objects
- [ ] Profile all 20 benchmarks, record results

#### 72.2: Targeted optimizations

- [ ] Fix top 3 bottlenecks identified in profiling
- [ ] Re-measure benchmarks after each fix
- [ ] Record improvements in bench/history.yaml

#### 72.3: GC assessment report

- [ ] Write `.dev/gc-assessment.md` with findings
- [ ] Recommend: proceed to Phase 73 or focus on other optimizations

---

## Phase 73: Generational GC (conditional on Phase 72 findings)

### Prerequisites

- Phase 72 assessment recommends GC improvement
- Profiling data shows GC is ≥ 15% of runtime in real workloads

### Design Considerations

- **Write barriers**: Track old→young pointers on mutation (set!, swap!, conj, etc.)
- **Nursery**: Small bump-allocator region, collected frequently
- **Tenured**: Current MarkSweepGc, collected rarely
- **Promotion**: Objects surviving N nursery collections → tenured
- **Thread safety**: Nursery per-thread? Or global nursery with lock?

### Risk Mitigation

- **Large scope**: Estimate 3-5 sub-phases minimum
- **Correctness critical**: One missed write barrier = use-after-free
- **Binary size**: GC complexity may add code. Monitor closely.
- **Regression risk**: Every GC change must pass full test suite + benchmarks
- Design D## decision BEFORE implementation

### Sub-tasks (tentative — refine after Phase 72)

#### 73.1: Design + D## decision

- [ ] Write detailed design in `.dev/gc-gen-design.md`
- [ ] D## entry in decisions.md
- [ ] Identify all mutation points that need write barriers

#### 73.2: Write barrier infrastructure

- [ ] Write barrier API
- [ ] Instrument all mutation points (atoms, volatiles, transients, etc.)
- [ ] Verify no missed barriers via comptime checks

#### 73.3: Nursery allocator

- [ ] Bump allocator for nursery
- [ ] Minor GC (nursery sweep)
- [ ] Promotion logic

#### 73.4: Integration + validation

- [ ] Full test suite pass
- [ ] Benchmark comparison (must improve, not regress)
- [ ] Stress test (long-running REPL, large data processing)

---

## Task Queue (for memo.md)

```
Phase 70: spec.alpha
  70.1: Infrastructure + Protocols
  70.2: Core Specs + Macros
  70.3: Regex Ops + Advanced
  70.4: gen stubs + spec.gen.alpha shell + upstream tests

Phase 71: Library Compatibility Testing
  71.1: medley
  71.2: hiccup
  71.3: clojure.data.json
  71.4: honeysql
  71.5: camel-snake-kebab

Phase 72: Optimization + GC Assessment
  72.1: Profiling infrastructure
  72.2: Targeted optimizations
  72.3: GC assessment report

Phase 73: Generational GC (conditional)
  73.1: Design + D## decision
  73.2: Write barrier infrastructure
  73.3: Nursery allocator
  73.4: Integration + validation
```

---

## References

| Topic | Location |
|-------|----------|
| spec.alpha upstream | `~/Documents/OSS/spec.alpha/` |
| spec.alpha source | `src/main/clojure/clojure/spec/alpha.clj` (1996 lines) |
| spec upstream tests | `src/test/clojure/clojure/test_clojure/spec.clj` (312 lines) |
| Non-functional baselines | `.dev/baselines.md` |
| GC current impl | `src/runtime/gc.zig` (MarkSweepGc) |
| Optimization catalog | `.dev/optimizations.md` |
| Deferred items | `.dev/checklist.md` |
