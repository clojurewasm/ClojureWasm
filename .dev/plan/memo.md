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

Phase order: ~~27~~ -> ~~28.1~~ -> ~~29 (skipped)~~ -> **30 (robustness)** -> 31 (FFI)

## Task Queue

Phase 30 — Production Robustness. Detailed plan: .dev/plan/phase30-robustness.md

- ~~30.1a Call stack tracking~~
- ~~30.1b Source context display~~
- ~~30.1c Throwable->map + ex-data~~
- ~~30.1d REPL error formatting~~
- 30.2a nREPL stacktrace op
- 30.2b nREPL info extension (:file, :line)
- 30.2c CIDER end-to-end test
- 30.3a require file resolution
- 30.3b src/ path auto-detect
- 30.3c cljw.edn support
- 30.4a letfn implementation
- 30.4b with-open macro
- 30.4c tagged-literal + reader-conditional
- 30.4d with-local-vars + with-in-str
- 30.4e Remaining type predicates

## Current Task

30.2a — nREPL stacktrace op. Implement CIDER-compatible stacktrace response.

## Previous Task

30.1e + REPL Line Editor — Added error messages to all UndefinedVar return
sites (30.1e). Implemented interactive REPL line editor (src/repl/line_editor.zig):
emacs keybindings, history (persistent ~/.cljw_history), multi-line continuation,
tab completion from namespace symbols, paren matching flash, C-c/C-d handling.
Non-TTY stdin falls back to simple reader for piped input.

## Known Issues from Phase 27

- ~~F111 RESOLVED: Bootstrap Symbol leaks fixed via Env.owned_symbols tracking.~~

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
