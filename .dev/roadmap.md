# ClojureWasm Roadmap

> **Context-efficient reading**: Read Phase Tracker to find the next pending phase,
> then read only that phase's detail section. Do NOT read the entire file every session.

## Phase Tracker

Status: DONE / IN-PROGRESS / PENDING / DEFERRED

| Phase | Name | Tier | Status |
|-------|------|------|--------|
| 1-76 | (see Completed Phases below) | — | DONE |
| 77 | Var Coverage Completion | 0 | DONE |
| 78 | Bug Fixes & Correctness | 1 | IN-PROGRESS |
| 79 | cl-format Implementation | 1 | PENDING |
| 80 | Crash Hardening & Fuzzing | 1 | PENDING |
| 81 | Error System Maturity | 1 | PENDING |
| 82 | CI/CD Foundation | 2 | PENDING |
| 83 | Essential Documentation | 2 | PENDING |
| 84 | Testing Expansion | 2 | PENDING |
| 85 | Library Compatibility Expansion | 2 | PENDING |
| 87 | Developer Experience | 3 | PENDING |
| 88 | v0.2.0 Release | 3 | PENDING |
| 86 | Distribution | 4 | PENDING |
| 89 | Performance Optimization | 4 | PENDING |
| 90 | JIT Expansion | 4 | PENDING |
| 92 | Security Hardening | 4 | PENDING |
| 93 | LSP Foundation | 4 | PENDING |
| 91 | wasm_rt Track | — | DEFERRED |
| 94 | API Stabilization | 5 | PENDING |
| 95 | Community Preparation | 5 | PENDING |
| 96 | v1.0.0 Release | 5 | PENDING |

### Tier Summary

| Tier | Goal | Phases |
|------|------|--------|
| 0 | Current work | 77 |
| 1 | Stabilize & Harden | 78-81 |
| 2 | Production Quality | 82-85 |
| 3 | DX & Release | 87-88 |
| 4 | Advanced Features & Distribution | 86, 89-90, 92-93 |
| 5 | Toward v1.0 | 94-96 |
| — | Deferred | 91 (wasm_rt) |

---

## Completed Phases (1-76)

Phases 1-76 cover: Reader, Analyzer, VM, TreeWalk, GC, builtins, core.clj bootstrap,
nREPL, CIDER compat, Wasm FFI, NaN boxing, JIT PoC, spec.alpha, deps.edn,
library compatibility testing, Java interop architecture, type system, reader enhancements.
See git history or `private/cw-report-2026-02-16.md` for full per-phase details.

---

## Phase 77: Var Coverage Completion (Tier 0, IN-PROGRESS)

77.10: Skip recovery audit — verify all skip/stub/todo vars have correct status and notes.
Includes: upstream test check, CLJW marker audit, benchmark coverage, documentation sync.

**Exit**: All vars have accurate status. No hidden TODO or broken stubs.

---

## Phase 78: Bug Fixes & Correctness (Tier 1)

| Sub | Task | Priority |
|-----|------|----------|
| 78.1 | ~~Fix F140: GC crash in dissocFn~~ — no longer reproducible | DONE |
| 78.2 | Fix F139: case macro with mixed body types | MUST |
| 78.3 | F94 upstream alignment pass (87 markers in src/clj/) | SHOULD |
| 78.4 | Audit all `unreachable` in production paths — convert to error returns | SHOULD |

**Exit**: Zero known crash bugs. F139 resolved. F94 markers reduced.

---

## Phase 79: cl-format Implementation (Tier 1)

The 4 remaining TODO vars. Large single task (~1,950 lines upstream).

| Sub | Task | Priority |
|-----|------|----------|
| 79.1 | cl-format core engine (directives, dispatch) | MUST |
| 79.2 | formatter macro | MUST |
| 79.3 | formatter-out macro | MUST |
| 79.4 | code-dispatch (pprint, uses formatter-out in ~30 places) | MUST |

**Exit**: 0 TODO vars. pprint fully functional with code formatting.

---

## Phase 80: Crash Hardening & Fuzzing (Tier 1)

Goal: "User code must never trigger a Zig panic."

**Methodology** (adopted from zwasm Stage 33 experience):
Phase-by-phase fuzzing — Reader, Analyzer, Compiler, VM individually.
Seed corpus from existing test files (52 upstream + e2e + deps tests).
Structure-aware generation for deeper coverage.
zwasm's approach found 3 bugs in 10K+ iterations that manual testing missed.

| Sub | Task | Priority |
|-----|------|----------|
| 80.1 | Coverage-guided fuzzing harness for Reader | MUST |
| 80.2 | Coverage-guided fuzzing harness for Analyzer | MUST |
| 80.3 | Coverage-guided fuzzing harness for Compiler + VM | SHOULD |
| 80.4 | Structure-aware input generation (Clojure form generator) | SHOULD |
| 80.5 | Differential testing harness (CW vs JVM Clojure) | MUST |
| 80.6 | Resource limits: nesting depth, string size, collection count | MUST |
| 80.7 | Audit `Internal Error` / `bootstrap evaluation error` — must never reach users | MUST |
| 80.8 | Vulnerability audit using CW-adapted checklist | MUST |
| 80.9 | Threat model document (CW trust boundaries) | SHOULD |

**Approach**: Zig `zig build fuzz` + LLVM sanitizer. All panics found → proper error returns.

**Vulnerability Audit Checklist** (derived from zwasm `02_vulnerability.md`):
- GC: use-after-free, double free, dangling pointer, GC memory corruption
- VM: stack overflow/underflow, unchecked bytecode jump, type confusion
- Clojure layer: eval injection, require path traversal, namespace poisoning,
  unbounded recursion, serialization bomb, infinite lazy sequence
- Interop: FFI memory escape, host function privilege, sandbox boundary
- Build: ReleaseSafe safety (bounds check, overflow detect preserved)

**Differential Testing**: Generate random Clojure expressions, run on both CW and
JVM Clojure (via clojure.jar), compare outputs. Automated regression — any
divergence = potential bug. zwasm used this vs wasmtime to find 3 spec violations.

**Exit**: Fuzzing runs 24h+ without panic. Resource limits enforced.
No Internal Error in user paths. Vulnerability audit complete. Threat model documented.

---

## Phase 81: Error System Maturity (Tier 1)

**Error Catalog Structure** (following zwasm `docs/errors.md` model):
Organize all CW errors by processing layer:

```
Reader → Analyzer → Compiler → VM → TreeWalk → Builtins → Interop
  EOF     Unresolved  ByteLimit   StackOvfl   EvalErr    ArityErr   ClassNotFound
  Syntax  ArityErr    CompileErr  Trap        TypeErr    TypeErr    MethodNotFound
  ...     ...         ...         OOM         ...        CastErr    ...
```

| Sub | Task | Priority |
|-----|------|----------|
| 81.1 | Build layered error catalog (Reader→Analyzer→Compiler→VM→Builtins→Interop) | MUST |
| 81.2 | Unknown class/method calls → clear user-friendly messages (not panic) | MUST |
| 81.3 | Interop error messages: list supported classes when unknown class used | MUST |
| 81.4 | Stack trace quality: source file + line for user code errors | SHOULD |
| 81.5 | Ensure no raw Zig error (error.Foo) leaks to user — all have human message | MUST |

**Reference**: zwasm `docs/errors.md` for catalog structure.
zwasm lesson: error layers clearly separated → faster debugging, better user messages.

**Exit**: Every error path produces a clear, actionable message.
Error catalog document in `docs/errors.md`. No raw Zig error leaks.

---

## Phase 82: CI/CD Foundation (Tier 2)

| Sub | Task | Priority |
|-----|------|----------|
| 82.1 | GitHub Actions: test matrix (macOS ARM64 + Linux x86_64) | MUST |
| 82.2 | ReleaseSafe build enforcement in CI | MUST |
| 82.3 | Benchmark regression detection (compare against baselines) | MUST |
| 82.4 | Binary size check in CI | MUST |
| 82.5 | Upstream test suite in CI | MUST |
| 82.6 | e2e + deps e2e tests in CI | MUST |
| 82.7 | Sanitizer CI job (ASan/UBSan) — periodic | SHOULD |
| 82.8 | Continuous fuzzing (nightly, from Phase 80 harness) | SHOULD |

**zwasm CI learnings**: zwasm runs full spec test (62K tests) + ReleaseSafe + both
platforms in CI. CW should similarly run full upstream suite + e2e + benchmarks.
ASan caught 2 memory bugs in zwasm that normal testing missed.

**Exit**: Every push tested on 2 platforms. Performance regressions caught automatically.
All e2e and upstream tests in CI.

---

## Phase 83: Essential Documentation (Tier 2)

Minimal viable documentation. No book, no README enrichment, no tutorial content.
Reference documents only — things users need to look up.

| Sub | Task | Priority |
|-----|------|----------|
| 83.1 | Compatibility Matrix (namespaces, vars, known diffs vs JVM Clojure) | MUST |
| 83.2 | Spec Differences doc (concrete behavioral diffs from JVM Clojure) | MUST |
| 83.3 | CLI Reference (all cljw flags and options) | MUST |
| 83.4 | Java Interop Reference (supported classes/methods/fields) | MUST |
| 83.5 | Error Reference (from Phase 81 catalog, user-facing version) | MUST |
| 83.6 | Wasm FFI Reference (wasm/load, wasm/fn, host functions) | SHOULD |

**Format**: Markdown in `docs/`. No build step. GitHub renders directly.
**Deferred**: Getting Started guide, Architecture Overview, Contributor Guide,
deps.edn guide, FAQ, Book-style tutorial — all deferred to later tiers.

**Exit**: A user can look up CW's capabilities, limitations, and API from docs.

---

## Phase 84: Testing Expansion (Tier 2)

| Sub | Task | Priority |
|-----|------|----------|
| 84.1 | Port remaining high-value upstream test files (target: 60+) | MUST |
| 84.2 | Differential testing campaign: CW vs JVM on upstream test expressions | MUST |
| 84.3 | Property-based tests for Reader round-trip: `print(read(x)) == normalize(x)` | SHOULD |
| 84.4 | Long-run stability: REPL session 1000+ evaluations, large file processing | SHOULD |
| 84.5 | Golden output tests for REPL sessions | SHOULD |
| 84.6 | Stress tests: heavy allocation + GC pressure scenarios | SHOULD |

**Differential Testing** (from zwasm Stage 33 methodology):
Expand Phase 80.5 harness into continuous regression suite.
Generate expressions (arithmetic, collection ops, string ops, lazy seqs),
run on CW + JVM Clojure, compare. Track divergence count over time.

**Long-run Stability** (from zwasm production readiness list):
Run CW REPL with 1000+ sequential evaluations including GC-heavy workloads.
Monitor: RSS growth, response time degradation, GC pause distribution.
Goal: no memory leak, no progressive slowdown.

**Exit**: 60+ upstream test files passing. Reader round-trip property verified.
Differential testing automated. Long-run stability confirmed.

---

## Phase 85: Library Compatibility Expansion (Tier 2)

Target list: `.dev/library-port-targets.md` (Batch 2-5).
Batch 1 (medley, CSK, honeysql) already tested and passing.

| Sub | Task | Priority |
|-----|------|----------|
| 85.1 | Batch 2: clojure.data.json, clojure.data.csv, instaparse | MUST |
| 85.2 | Batch 3: malli, clojure.core.match | SHOULD |
| 85.3 | Document library compatibility results in `docs/compatibility.md` | MUST |
| 85.4 | F141: cljw.xxx aliases for clojure.java.xxx namespaces | SHOULD |

**Approach**: Test libraries as-is (no forking). Fix CW when tests fail.
Each library test run uncovers CW implementation gaps — fix in CW, not the library.

**Exit**: 10+ real libraries tested. Compatibility matrix updated with results.

---

## Phase 87: Developer Experience (Tier 3)

| Sub | Task | Priority |
|-----|------|----------|
| 87.1 | `cljw test` command (run clojure.test from project) | MUST |
| 87.2 | nREPL ops expansion (test, macroexpand, stacktrace) | SHOULD |
| 87.3 | REPL polish (multiline improvements, tab completion) | SHOULD |
| 87.4 | Project template (`cljw new my-app`) | COULD |

**Exit**: End-to-end project workflow: develop → test → run.

---

## Phase 88: v0.2.0 Release (Tier 3)

| Sub | Task | Priority |
|-----|------|----------|
| 88.1 | Version bump + CHANGELOG | MUST |
| 88.2 | Release notes | MUST |
| 88.3 | Benchmark record (full history entry) | MUST |
| 88.4 | Binary audit (no debug symbols, no embedded secrets) | MUST |
| 88.5 | GitHub Release with pre-built binaries (macOS ARM64 + Linux x86_64) | MUST |
| 88.6 | Cross-platform smoke test before release | MUST |

**Exit**: Tagged v0.2.0 on GitHub with binaries, release notes, and changelog.

---

## Phase 86: Distribution (Tier 4)

Deferred from Tier 3. Tackle when user base justifies distribution infrastructure.

| Sub | Task | Priority |
|-----|------|----------|
| 86.1 | Homebrew tap (macOS) | MUST |
| 86.2 | Signed releases | SHOULD |
| 86.3 | Docker image | COULD |
| 86.4 | Nix package | COULD |

**Exit**: `brew install clojurewasm/tap/cljw` works.

---

## Phase 89: Performance Optimization (Tier 4)

| Sub | Task | Expected Impact | Effort |
|-----|------|-----------------|--------|
| 89.1 | F102: map/filter chunked processing | Lazy-seq alloc reduction | Medium |
| 89.2 | Generational GC (nursery + tenured) | 2-5x allocation throughput | High |
| 89.3 | F103: Escape analysis (compiler-level) | Skip GC for local values | High |
| 89.4 | Closure stack allocation (small closures) | Avoid heap for 1-2 captures | Medium |
| 89.5 | Benchmark + record after each optimization | — | Low |

**Gate**: Full benchmark suite, no regression, record to history.yaml.

---

## Phase 90: JIT Expansion (Tier 4)

| Sub | Task | Priority |
|-----|------|----------|
| 90.1 | x86_64 JIT backend (port ARM64 patterns) | SHOULD |
| 90.2 | Expand JIT beyond integer loops (float, collection ops) | COULD |
| 90.3 | JIT warmup analysis + adaptive compilation threshold | COULD |

**Exit**: JIT on both ARM64 and x86_64. Hot loops consistently JIT-compiled.

---

## Phase 91: wasm_rt Track (DEFERRED)

Compile CW runtime to .wasm, run on Wasm edge runtimes.
Key differentiator but not priority for current development cycle.
Revisit after v0.2.0 when distribution and DX are solid.

| Sub | Task | Priority |
|-----|------|----------|
| 91.1 | PoC: `zig build -Dtarget=wasm32-wasi` with full CW runtime | MUST |
| 91.2 | WASI integration (preopened dirs, env, args) | MUST |
| 91.3 | Bundle user .clj + core.clj + runtime into single .wasm | MUST |
| 91.4 | `cljw build --target wasm` command | SHOULD |
| 91.5 | Test on Wasmtime, WasmEdge, Deno Deploy | SHOULD |
| 91.6 | Startup optimization for .wasm (AOT bytecode embedding) | COULD |

**Exit**: `cljw build --target wasm` produces a .wasm that runs on Wasmtime.
**Reference**: `.dev/future.md` SS1, SS7, SS21.

---

## Phase 92: Security Hardening (Tier 4)

| Sub | Task | Priority |
|-----|------|----------|
| 92.1 | Expand Phase 80.9 threat model (CW + zwasm combined) | MUST |
| 92.2 | Sandbox mode: `--allow-read`, `--allow-write`, `--allow-net` | SHOULD |
| 92.3 | Leverage zwasm `--sandbox` mode for Wasm FFI isolation | SHOULD |
| 92.4 | W^X enforcement verification for JIT | SHOULD |
| 92.5 | Security disclosure policy (SECURITY.md) | MUST |
| 92.6 | Deterministic mode (reproducible execution) | COULD |
| 92.7 | SBOM generation | COULD |

**Reference**: zwasm `docs/security.md` (threat model), `07_security_analysis_report.md`.
zwasm already has deny-by-default WASI, fuel limits, W^X, `--sandbox` flag.
CW inherits these for Wasm FFI. CW-specific threats: eval injection, require path
traversal, namespace poisoning — addressed in Phase 80.8.

---

## Phase 93: LSP Foundation (Tier 4)

| Sub | Task | Priority |
|-----|------|----------|
| 93.1 | LSP server basics: textDocument/didOpen, didChange | MUST |
| 93.2 | Go-to-definition (var resolution) | MUST |
| 93.3 | Completion (namespace vars, keywords) | SHOULD |
| 93.4 | Diagnostics (syntax errors, unresolved symbols) | SHOULD |
| 93.5 | VSCode extension packaging | COULD |

---

## Phase 94: API Stabilization (Tier 5)

| Sub | Task | Priority |
|-----|------|----------|
| 94.1 | Public API boundary definition (embedding, CLI, nREPL) | MUST |
| 94.2 | Stability annotations (stable / experimental / internal) | MUST |
| 94.3 | Deprecation policy | MUST |
| 94.4 | SemVer commitment | MUST |

**Reference**: zwasm `docs/api-boundary.md` as model (stable/experimental/internal classification).

---

## Phase 95: Community Preparation (Tier 5)

| Sub | Task | Priority |
|-----|------|----------|
| 95.1 | Code of Conduct | MUST |
| 95.2 | CONTRIBUTING.md (move from .dev/ to repo root) | MUST |
| 95.3 | Issue templates (bug report, feature request) | SHOULD |
| 95.4 | Public roadmap on GitHub | SHOULD |

---

## Phase 96: v1.0.0 Release (Tier 5)

| Sub | Task | Priority |
|-----|------|----------|
| 96.1 | Full test suite pass (upstream + e2e + deps + fuzz + differential) | MUST |
| 96.2 | Performance baseline freeze | MUST |
| 96.3 | Documentation complete (expand Phase 83 to full coverage) | MUST |
| 96.4 | Security audit (self-audit with vulnerability checklist) | MUST |
| 96.5 | Cross-platform verification (macOS ARM64, Linux x86_64, Linux aarch64) | MUST |
| 96.6 | Tag + release + announcement | MUST |

---

## Phase Dependencies

```
77 ──► 78 ──► 79 ──► 80 ──► 81
                      │
                      ▼
                     82 ──► 83
                      │      │
                      ▼      ▼
                     84     85 ──► 87 ──► 88 (v0.2.0)
                      │                    │
                      └────────────────────┘

88 ──► 86 (distribution, deferred)
88 ──► 89 ──► 90
80 ──► 92 (security, builds on fuzzing)
83 ──► 93 (LSP, needs stable docs)

88 ──► 94 ──► 95 ──► 96 (v1.0)

91 (wasm_rt) — DEFERRED, no dependencies blocking
```

---

## Phase Notes

### Implementation Tier Reference

See `.claude/references/impl-tiers.md`.

| Tier | Location | Criteria |
|------|----------|----------|
| 1 | Zig builtin | Low-level, hot path, perf-critical |
| 2 | core.clj | Pure Clojure, existing fn combinations |
| 3 | Skip | JVM-specific (threading, reflection) |
| 4 | Zig stub | Dynamic vars, config |

### zwasm Dependencies

zwasm is a separate project (`../zwasm/`). Current: v1.1.0, 62,158/62,158 spec (100%).

| Item | Impact on CW | When | zwasm Status |
|------|-------------|------|-------------|
| Security audit | CW sandbox depends on zwasm safety | Before CW v1.0 | Stage 36 done |
| x86_64 JIT | CW Wasm perf on Linux | Tier 4 | Stage 13 done |
| Wasm spec 100% | Confidence in correctness | Before CW v1.0 | Stage 32 done (100%) |
| `--sandbox` mode | CW Wasm FFI isolation | Phase 92 | v1.0.0 done |
| Deny-by-default API | CW bridge safety | Applied | v1.1.0 (`cli_default`) |
| Fuzz testing | CW Wasm layer confidence | Phase 80 | Stage 33 done (10K+, 0 crashes) |
| Threat model | CW security doc reference | Phase 80/92 | `docs/security.md` done |
| Error catalog | CW error system reference | Phase 81 | `docs/errors.md` done |

**Rule**: Wasm engine changes go in zwasm repo, not CW. CW bridge: `src/wasm/types.zig`.

### Open Checklist Items (checklist.md)

| ID | Item | Target Phase |
|----|------|-------------|
| F94 | Upstream alignment pass | 78.3 |
| F102 | map/filter chunked processing | 89.1 |
| F103 | Escape analysis | 89.3 |
| F104 | Profile-guided IC extension | 89 (stretch) |
| F105 | JIT expansion | 90 |
| F120 | Native SIMD optimization | 89 (stretch) |
| F139 | case macro mixed body types | 78.2 |
| F140 | GC crash in dissocFn | 78.1 |
| F141 | cljw.xxx aliases | 85.4 |

### Stub Resolution Strategy (27 stubs)

| Category | Count | Resolution |
|----------|-------|------------|
| Dynamic var defaults (*in*, *out*, *err*, etc.) | 15 | Acceptable — CW I/O pipeline covers functionality |
| Socket REPL (start-server, prepl, etc.) | 4 | Defer — CW has nREPL |
| Library management (add-lib, add-libs, sync-deps) | 3 | Defer — needs Maven/Clojars |
| inst range (inst-in, inst-in-range?) | 2 | Defer — needs Date type |
| test.check (quick-check, for-all*) | 2 | Consider in Phase 80 (useful for fuzzing) |
| pprint-tab | 1 | Acceptable — upstream also "not yet implemented" |

### Success Metrics

**v0.2.0 (End of Tier 3)**:
- Zero known crash bugs
- 0 TODO vars (cl-format done)
- 60+ upstream test files passing
- 10+ real libraries tested with documented results
- Differential testing automated (CW vs JVM)
- CI running on macOS + Linux
- Essential reference docs (Compatibility Matrix, CLI Reference, Error Reference)
- GitHub Release with pre-built binaries

**v1.0.0 (End of Tier 5)**:
- 24h+ fuzz run without panic
- Security audit complete (CW + zwasm combined threat model)
- LSP with go-to-def + completion
- Distribution: Homebrew + signed releases
- Cross-platform verified
- Public API frozen with stability guarantees
- Full documentation (expand beyond essential reference)
