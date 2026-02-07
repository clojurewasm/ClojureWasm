# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 28.1 complete (A, BE, B, C, CX, R, D, 20-28.1, 22b, 22c, 24.5)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 28.1 COMPLETE** — Single Binary Builder MVP (1.7MB binary)
- **Phase 29 SKIPPED** — File splitting impractical (Zig struct constraint),
  D3 violations require BuiltinFn signature change (500+ functions)
- **Phase 30 IN PROGRESS** — Production Robustness

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> ~~29 (skipped)~~ -> **30 (robustness)** -> 31 (AOT) -> 32 (GC/JIT research) -> 33 (FFI deep)

## Task Queue

Phase 30 — Production Robustness. Detailed plan: .dev/plan/phase30-robustness.md

- ~~30.1a Call stack tracking~~
- ~~30.1b Source context display~~
- ~~30.1c Throwable->map + ex-data~~
- ~~30.1d REPL error formatting~~
- ~~30.2a nREPL stacktrace op~~
- ~~30.2b nREPL info extension (:file, :line)~~
- ~~30.2c Modular dispatch + describe~~
- ~~30.2d CIDER end-to-end verification~~
- ~~30.3a require file resolution~~
- ~~30.3b src/ path auto-detect~~
- ~~30.3c cljw.edn support~~
- ~~30.4a letfn implementation~~
- ~~30.4b with-open macro~~
- ~~30.4c tagged-literal + reader-conditional~~
- ~~30.4d with-local-vars + with-in-str~~
- 30.4e Remaining type predicates
- 30.5a doc macro
- 30.5b dir
- 30.5c apropos + find-doc
- 30.5d source + pst

## Current Task

30.4e — Remaining type predicates. bytes?, uri?, uuid? etc.

## Previous Task

30.4d — with-local-vars + with-in-str. with-local-vars implemented using
create-local-var builtin + push/pop-thread-bindings. Fixed var-set to use
setThreadBinding (was incorrectly using bindRoot). Added __var-bind-root for
with-redefs-fn. with-in-str deferred (requires *in*/StringReader).

## Known Issues

- ~~F111 RESOLVED: Bootstrap Symbol leaks fixed via Env.owned_symbols tracking.~~
- ~~F112 RESOLVED: nREPL Var corruption from shared ArenaAllocator (D80). eval_arena removed, GPA-only.~~
- F113 OPEN: nREPL lacks GC — transient Values accumulate via GPA. Bounded
  for typical REPL sessions (proportional to unique evaluated code). Not a
  correctness issue; same behavior as main.zig interactive REPL.

## Handover Notes

- **Phase 30 plan**: .dev/plan/phase30-robustness.md
- **Phase 28 plan**: .dev/plan/phase28-single-binary.md
- **Roadmap**: .dev/plan/roadmap.md — Phases 27-31 defined
- **wasm_rt archive**: .dev/plan/phase26-wasm-rt.md + src/wasm_rt/README.md
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **NaN boxing (D72)**: COMPLETE. Value 48B→8B. 17 commits (27.1-27.4).
- **Single binary**: Binary trailer approach (Deno-style). No Zig needed on user machine.
  Format: [cljw binary] + [.clj source] + [u64 size] + "CLJW" magic.
- **macOS signing**: Ad-hoc resign with `codesign -s - -f` after build.
  Proper section injection deferred.
- **nREPL/CIDER**: Phase 30.2 complete. 14 ops (eval, clone, close, describe,
  load-file, ls-sessions, completions, info, eldoc, ns-list, stacktrace,
  analyze-last-stacktrace, stdin, interrupt). Start: `cljw --nrepl-server --port=0`
- **Var metadata**: doc/arglists propagated from defn→analyzer→DefNode→Var.
  Arglists auto-extracted from fn form. File/line set for all def forms.
