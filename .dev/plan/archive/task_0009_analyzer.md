# Task 0009: Create Analyzer with special form comptime table

## Context
- Phase: 1c (Analyzer)
- Depends on: task_0008 (Node type), task_0007 (Reader)
- References: Beta src/analyzer/analyze.zig (5355L), future.md SS10

## Plan

### Design: comptime special form dispatch

Unlike Beta's if-else chain (216-266), use a comptime string map:

```zig
const SpecialFormFn = *const fn (*Analyzer, []const Form) AnalyzeError!*Node;

const special_forms = std.StaticStringMap(SpecialFormFn).initComptime(.{
    .{ "if",       analyzeIf },
    .{ "do",       analyzeDo },
    .{ "let",      analyzeLet },
    .{ "let*",     analyzeLet },
    .{ "fn",       analyzeFn },
    .{ "fn*",      analyzeFn },
    .{ "def",      analyzeDef },
    .{ "quote",    analyzeQuote },
    .{ "defmacro", analyzeDefmacro },
});
```

### Phase 1c scope (no runtime)

- No Env/Namespace/Var yet (Phase 2)
- Symbol resolution: unresolved symbols become var_ref with name-only
- No macro expansion (defmacro records DefNode with is_macro=true)
- No destructuring (simple bindings only)
- formToValue for quote

### Implementation steps (TDD)

1. **Analyzer struct**: allocator, locals stack, source tracking, error helpers
2. **analyze() dispatch**: literal forms -> constant, list -> special form or call
3. **analyzeIf**: (if test then else?)
4. **analyzeDo**: (do stmt...)
5. **analyzeLet**: (let [bindings...] body...) - simple symbols only
6. **analyzeFn**: (fn name? [params] body...) and multi-arity
7. **analyzeDef**: (def name init?)
8. **analyzeQuote**: (quote form) with formToValue
9. **analyzeDefmacro**: (defmacro name [params] body) -> DefNode with is_macro
10. **analyzeSymbol**: local resolution -> local_ref, else -> var_ref
11. **analyzeCall**: (f arg1 arg2...)
12. **Collection literals**: vector, map, set -> constant nodes
13. **Error helpers**: analysisError, analysisErrorFmt in error.zig
14. Wire up in root.zig

### Key differences from Beta

- comptime StaticStringMap dispatch (not if-else chain)
- No Env dependency (name-based var_ref)
- No destructuring (deferred)
- No macro expansion (deferred to Task 1.12+)
- `source` field naming (not `stack`)
- `callee` field in CallNode (not `fn_node`)

## Log

## Status: done

### 2026-02-01
- Created src/common/analyzer/analyzer.zig with:
  - Analyzer struct with allocator, locals stack, source tracking
  - comptime StaticStringMap dispatch for 9 special form entries:
    if, do, let, let*, fn, fn*, def, quote, defmacro
  - analyzeIf: (if test then else?) with optional else
  - analyzeDo: (do stmt...) wrapping in DoNode
  - analyzeLet: (let [x 1 y 2] body) with local binding + scoping
  - analyzeFn: single and multi-arity, variadic (&), named fn self-reference
  - analyzeDef: (def name init?)
  - analyzeQuote: (quote form) with formToValue
  - analyzeDefmacro: (defmacro name [params] body) -> DefNode with is_macro
  - analyzeSymbol: local lookup -> local_ref, else -> var_ref (name-based)
  - analyzeCall: (f arg1 arg2...) -> CallNode
  - Collection literals: vector/map/set -> constant if all-const, else builtin call
  - formToValue: primitive Form -> Value conversion for quote
  - Error helpers: analysisError with AnalyzeError narrowing
- Added AnalysisError type and analysisError/analysisErrorFmt to error.zig
- Wired up in root.zig
- 20 tests covering all node types, scoping, error cases. All passing
