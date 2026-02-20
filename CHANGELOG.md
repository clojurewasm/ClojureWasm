# Changelog

## v0.3.0 (2026-02-20)

### Architecture v2
- Exception system unification: `Exception.` returns maps with hierarchy and `.getMessage`
- ClassDef registry for unified interop dispatch (protocol-based)
- UTF-8 codepoint correctness for all string operations
- Handle memory safety with use-after-close detection
- Scope-reduced All-Zig migration: hybrid architecture (Zig primitives + .clj composition) confirmed optimal

### Crash Hardening
- Coverage-guided fuzzing harnesses for Reader, Analyzer, Compiler, and VM
- Structure-aware Clojure form generator for fuzzing
- Differential testing harness (CW vs JVM Clojure): 146 static + 100 random expressions
- Resource limits for format, str, and analyzer depth
- Internal error audit and panic removal
- Vulnerability audit with VM hardening

### Error System
- Layered error catalog (docs/errors.md)
- Improved class/method error messages with suggestions

### Testing
- 63 upstream test files (62/63 passing)
- 13 CW-specific test files (exceptions, sorted collections, threading, destructuring, etc.)
- Reader round-trip, stability, REPL output, and GC stress tests
- Differential testing expanded to 146 expressions

### Library Compatibility
- `cljw.io`, `cljw.shell`, `cljw.browse`, `cljw.process` namespace aliases
- Library compatibility matrix: medley (82.5%), clojure.walk (100%), clojure.set (100%), data.csv (100%)

### Developer Experience
- `cljw new <name>`: project scaffolding with deps.edn, src/, test/
- nREPL macroexpand op (supports macroexpand, macroexpand-1, macroexpand-all)
- REPL namespace-qualified tab completion (e.g., `str/tri<TAB>`)
- REPL special commands: `:quit`, `:help`
- Fixed nREPL cons cell rendering (sequences, not dotted pairs)
- Fixed nREPL server shutdown panic

### CI/CD
- GitHub Actions CI/CD foundation

### Bug Fixes
- def/defn now returns var (Clojure compatibility)
- macroexpand-1 qualified names
- apply variadic dispatch
- list* with cons/lazy-seq tails
- Lazy-seq display uses formatPrStr

## v0.2.0 (2026-02-13)

Initial public release with zwasm v1.1.0 integration.

## v0.1.0 (2026-02-13)

First tagged release.
