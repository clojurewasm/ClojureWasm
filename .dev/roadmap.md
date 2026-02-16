# ClojureWasm Roadmap

> **Context-efficient reading**: Read Phase Tracker to find the next pending phase,
> then read only that phase's detail section. Do NOT read the entire file every session.

## Phase Tracker

Status: DONE / IN-PROGRESS / PENDING

| Phase | Name | Tier | Status |
|-------|------|------|--------|
| 1-76 | (see Completed Phases below) | — | DONE |
| 77 | Var Coverage Completion | 0 | IN-PROGRESS |
| 78 | Bug Fixes & Correctness | 1 | PENDING |
| 79 | cl-format Implementation | 1 | PENDING |
| 80 | Crash Hardening & Fuzzing | 1 | PENDING |
| 81 | Error System Maturity | 1 | PENDING |
| 82 | CI/CD Foundation | 2 | PENDING |
| 83 | Documentation | 2 | PENDING |
| 84 | Upstream Test Expansion | 2 | PENDING |
| 85 | Library Compatibility Expansion | 2 | PENDING |
| 86 | Distribution | 3 | PENDING |
| 87 | Developer Experience | 3 | PENDING |
| 88 | v0.2.0 Release | 3 | PENDING |
| 89 | Performance Optimization | 4 | PENDING |
| 90 | JIT Expansion | 4 | PENDING |
| 91 | wasm_rt Track | 4 | PENDING |
| 92 | Security Hardening | 4 | PENDING |
| 93 | LSP Foundation | 4 | PENDING |
| 94 | API Stabilization | 5 | PENDING |
| 95 | Community Preparation | 5 | PENDING |
| 96 | v1.0.0 Release | 5 | PENDING |

### Tier Summary

| Tier | Goal | Phases |
|------|------|--------|
| 0 | Current work | 77 |
| 1 | Stabilize & Harden | 78-81 |
| 2 | Production Quality | 82-85 |
| 3 | Ecosystem & Distribution | 86-88 |
| 4 | Advanced Features | 89-93 |
| 5 | Toward v1.0 | 94-96 |

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
| 78.1 | Fix F140: GC crash in dissocFn (keyword pointer freed) | MUST |
| 78.2 | Fix F139: case macro with mixed body types | MUST |
| 78.3 | F94 upstream alignment pass (87 markers in src/clj/) | SHOULD |
| 78.4 | Audit all `unreachable` in production paths — convert to error returns | SHOULD |

**Exit**: Zero known crash bugs. F140/F139 resolved. F94 markers reduced.

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

| Sub | Task | Priority |
|-----|------|----------|
| 80.1 | Coverage-guided fuzzing harness for Reader | MUST |
| 80.2 | Coverage-guided fuzzing harness for Analyzer | MUST |
| 80.3 | Coverage-guided fuzzing harness for Compiler + VM | SHOULD |
| 80.4 | Structure-aware input generation (Clojure form generator) | SHOULD |
| 80.5 | Differential testing harness (CW vs JVM Clojure) | SHOULD |
| 80.6 | Resource limits: nesting depth, string size, collection count | MUST |
| 80.7 | Audit `Internal Error` / `bootstrap evaluation error` — must never reach users | MUST |

**Approach**: Zig `zig build fuzz` + LLVM sanitizer. Phase-by-phase fuzzing
(Reader, Analyzer, Compiler, VM separately). All panics found -> proper error returns.

**Exit**: Fuzzing runs 24h+ without panic. Resource limits enforced. No Internal Error in user paths.

---

## Phase 81: Error System Maturity (Tier 1)

| Sub | Task | Priority |
|-----|------|----------|
| 81.1 | Catalog all error types and ensure consistent error messages | MUST |
| 81.2 | Unknown class/method calls -> clear user-friendly messages (not panic) | MUST |
| 81.3 | Interop error messages: list supported classes when unknown class used | SHOULD |
| 81.4 | Stack trace quality: source file + line for user code errors | SHOULD |

**Exit**: Every error path produces a clear, actionable message. No raw Zig error leaks.

---

## Phase 82: CI/CD Foundation (Tier 2)

| Sub | Task | Priority |
|-----|------|----------|
| 82.1 | GitHub Actions: test matrix (macOS ARM64 + Linux x86_64) | MUST |
| 82.2 | ReleaseSafe build enforcement in CI | MUST |
| 82.3 | Benchmark regression detection (compare against baselines) | MUST |
| 82.4 | Binary size check in CI | SHOULD |
| 82.5 | Upstream test suite in CI | SHOULD |
| 82.6 | Sanitizer CI job (ASan/UBSan) — periodic | COULD |
| 82.7 | Continuous fuzzing (nightly) | COULD |

**Exit**: Every push tested on 2 platforms. Performance regressions caught automatically.

---

## Phase 83: Documentation (Tier 2)

| Sub | Task | Priority |
|-----|------|----------|
| 83.1 | Getting Started (install, Hello World, REPL) | MUST |
| 83.2 | Compatibility Matrix (namespaces, vars, known diffs) | MUST |
| 83.3 | Spec Differences doc (concrete JVM Clojure diffs) | MUST |
| 83.4 | CLI Reference (all cljw flags and options) | MUST |
| 83.5 | Java Interop Reference (supported classes/methods/fields) | MUST |
| 83.6 | Wasm FFI Guide (wasm/load, wasm/fn, host functions) | SHOULD |
| 83.7 | deps.edn Guide (project setup, git deps, aliases) | SHOULD |
| 83.8 | Architecture Overview (compiler pipeline, dual backend, GC) | SHOULD |
| 83.9 | Contributor Guide (build, test, PR process) | SHOULD |
| 83.10 | FAQ / Troubleshooting | COULD |

**Format**: Markdown in `docs/`. No build step. GitHub renders directly.

**Exit**: A new user can install, run, and understand CW's scope from documentation alone.

---

## Phase 84: Upstream Test Expansion (Tier 2)

| Sub | Task | Priority |
|-----|------|----------|
| 84.1 | Port remaining high-value upstream test files (target: 60+) | MUST |
| 84.2 | Golden output tests for REPL sessions | SHOULD |
| 84.3 | Property-based tests for Reader round-trip | SHOULD |
| 84.4 | Stress tests: long-running REPL, large file processing | SHOULD |

**Exit**: 60+ upstream test files passing. Reader round-trip property verified.

---

## Phase 85: Library Compatibility Expansion (Tier 2)

| Sub | Task | Priority |
|-----|------|----------|
| 85.1 | Batch 2 libraries (clojure.data.json, clojure.data.csv, etc.) | MUST |
| 85.2 | Batch 3 libraries (ring-core subset, compojure subset, etc.) | SHOULD |
| 85.3 | Document library compatibility results in docs/ | MUST |
| 85.4 | F141: cljw.xxx aliases for clojure.java.xxx namespaces | SHOULD |

**Exit**: 10+ real libraries tested. Compatibility matrix updated with results.

---

## Phase 86: Distribution (Tier 3)

| Sub | Task | Priority |
|-----|------|----------|
| 86.1 | Homebrew tap (macOS) | MUST |
| 86.2 | Binary releases (GitHub Releases, multi-platform) | MUST |
| 86.3 | Signed releases | SHOULD |
| 86.4 | Docker image | COULD |
| 86.5 | Nix package | COULD |

**Exit**: `brew install clojurewasm/tap/cljw` works. GitHub Releases has macOS + Linux binaries.

---

## Phase 87: Developer Experience (Tier 3)

| Sub | Task | Priority |
|-----|------|----------|
| 87.1 | `cljw test` command (run clojure.test from project) | MUST |
| 87.2 | Project template (`cljw new my-app`) | SHOULD |
| 87.3 | nREPL ops expansion (test, macroexpand, stacktrace) | SHOULD |
| 87.4 | REPL polish (multiline improvements, tab completion) | SHOULD |
| 87.5 | Migration Guide: from JVM Clojure | COULD |
| 87.6 | Migration Guide: from Babashka | COULD |
| 87.7 | Examples collection (CLI tool, data processing, Wasm interop) | SHOULD |

**Exit**: End-to-end project workflow: create -> develop -> test -> run.

---

## Phase 88: v0.2.0 Release (Tier 3)

| Sub | Task | Priority |
|-----|------|----------|
| 88.1 | Version bump + CHANGELOG | MUST |
| 88.2 | Release notes | MUST |
| 88.3 | Benchmark record (full history entry) | MUST |
| 88.4 | Binary audit (no debug symbols, no embedded secrets) | MUST |
| 88.5 | README update with current stats | MUST |

**Exit**: Tagged v0.2.0 on GitHub with binaries, docs, and changelog.

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

## Phase 91: wasm_rt Track (Tier 4)

The key differentiator: compile CW runtime to .wasm, run on Wasm edge runtimes.

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
| 92.1 | Threat model document (CW + zwasm) | MUST |
| 92.2 | Sandbox mode: `--allow-read`, `--allow-write`, `--allow-net` | SHOULD |
| 92.3 | Deterministic mode (reproducible execution) | COULD |
| 92.4 | W^X enforcement verification for JIT | SHOULD |
| 92.5 | SBOM generation | COULD |
| 92.6 | Security disclosure policy (SECURITY.md) | MUST |

**Reference**: `.dev/future.md` SS14, `private/production_ready/02_vulnerability.md`

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
| 96.1 | Full test suite pass (upstream + e2e + deps + fuzz) | MUST |
| 96.2 | Performance baseline freeze | MUST |
| 96.3 | Documentation complete | MUST |
| 96.4 | Security audit (self-audit with vulnerability checklist) | MUST |
| 96.5 | Cross-platform verification (macOS ARM64, Linux x86_64, Linux aarch64) | MUST |
| 96.6 | Tag + release + announcement | MUST |

---

## Phase Dependencies

```
77 ──► 78 ──► 79 ──► 80 ──► 81
              │      │
              ▼      ▼
             82     84
              │      │
              ▼      ▼
             83     85 ──► 88 (v0.2.0)
              │             ▲
              ▼             │
             86 ────────────┘
              │
             87

88 ──► 89 ──► 90
       │
88 ──► 91 (wasm_rt, independent)
80 ──► 92 (security, builds on fuzzing)
83 ──► 93 (LSP, needs stable API docs)

88 ──► 94 ──► 95 ──► 96 (v1.0)
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

zwasm is a separate project (`../zwasm/`). Key milestones affecting CW:

| Item | Impact on CW | When |
|------|-------------|------|
| Security audit | CW sandbox depends on zwasm safety | Before CW v1.0 |
| x86_64 JIT in zwasm | CW Wasm perf on Linux | Tier 4 |
| Wasm spec test full pass | Confidence in correctness | Before CW v1.0 |

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
- Homebrew installable
- Documentation covers Getting Started + Compatibility + CLI Reference
- CI running on macOS + Linux

**v1.0.0 (End of Tier 5)**:
- 24h+ fuzz run without panic
- Security audit complete
- wasm_rt track functional (user .clj -> .wasm)
- LSP with go-to-def + completion
- Cross-platform verified
- Public API frozen with stability guarantees
