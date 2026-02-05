# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: R (require/load/ns system)
- Next task: Plan Phase D
- Coverage: 467/703 clojure.core vars done
- Blockers: none

## Task Queue

Phase D: Parallel expansion — implement remaining vars + skip JVM-only.
262 todo vars: ~90 JVM-skip, ~170 implementable. Target: 433 → 550+.

- D1: JVM-skip batch — mark ~90 JVM-specific vars as skip
  - Agents: agent, agent-error, agent-errors, send, send-off, send-via, await, await-for,
    await1, restart-agent, shutdown-agents, set-agent-send-executor/off-executor, etc.
  - Java arrays: aclone, aget, alength, amap, areduce, aset-*, *-array, make-array,
    into-array, to-array, to-array-2d, vector-of, floats, ints, longs, shorts, bytes, chars
  - Refs/STM: ref, ref-set, alter, commute, dosync, sync, ref-history-*, io!
  - Proxy/reify/gen-class: proxy-*, reify, gen-class, gen-interface, definterface
  - Other JVM: compile, add-classpath, bean, bases, supers, class?, import, memfn,
    get-proxy-class, init-proxy, update-proxy, proxy-call-with-super,
    primitives-classnames, print-ctor, method-sig, resultset-seq
- D2: Dynamic vars batch — register stub vars
  - Print: *print-dup*, *print-length*, *print-level*, *print-meta*, *print-readably*,
    *print-namespace-maps*, *flush-on-newline*
  - IO: *err*, *in*, *out*, *file*, *e
  - Reader: *read-eval*, *data-readers*, *default-data-reader-fn*
  - Other: *command-line-args*, *source-path*, *repl*, *unchecked-math*,
    *warn-on-reflection* (already skip?), *verbose-defrecords*
- D3: Exception & var system — ex-cause, find-var, resolve, intern, loaded-libs
- D4: Atom watchers & validators — add-watch, remove-watch, set-validator!, get-validator
- D5: Hashing — hash-combine, hash-ordered-coll, hash-unordered-coll, mix-collection-hash
- D6: refer-clojure + ns enhancements — refer-clojure with :exclude
- D7: Sorted collections — sorted-map-by, sorted-set-by, subseq, rsubseq
- D8: UUID/data readers — random-uuid, parse-uuid, uuid?, uri?, tagged-literal,
  tagged-literal?, reader-conditional, reader-conditional?
- D9: Transient collections — transient, persistent!, assoc!, conj!, disj!, dissoc!, pop!
- D10: Unchecked math — unchecked-byte/char/int/long/short/double/float,
  unchecked-divide-int, unchecked-remainder-int
- D11: IO macros — with-open, with-out-str, with-in-str
- D12: Binding & redefs — with-bindings, with-redefs, with-redefs-fn, with-local-vars,
  bound-fn, bound-fn*, thread-bound?
- D13: Misc functions — destructure, map-entry?, munge, namespace-munge,
  char-escape-string, char-name-string, find-keyword, re-groups, re-matcher
- D14: Read system — read, load-string, load-reader
- D15: Chunked seqs — chunk, chunk-append, chunk-buffer, chunk-first, chunk-next,
  chunk-rest, chunked-seq?
- D16: Concurrency stubs — promise, deliver, future, future-call, future-done?,
  future-cancel, future-cancelled?, future?, pmap, pcalls, pvalues, locking
- D17: Remaining misc — eduction, iteration, letfn, line-seq, file-seq,
  add-tap, remove-tap, tap>, requiring-resolve, seque, defstruct, struct, struct-map,
  create-struct, accessor, ->ArrayChunk, ->Eduction, ->Vec, ->VecNode, ->VecSeq,
  EMPTY-NODE, PrintWriter-on, StackTraceElement->vec, Throwable->map

## Current Task

D4: Atom watchers & validators — add-watch, remove-watch, set-validator!, get-validator.

## Previous Task

D3 completed: Exception & var system + map-entry? — 7 new builtins.
- ex-cause, find-var, resolve, intern, loaded-libs, map-entry?
- Status: 467 done, 131 skip, 105 todo

D2 completed: Dynamic vars batch — 27 vars registered.
- 21 dynamic vars in registerBuiltins (print, IO, reader, misc)
- unquote/unquote-splicing as constant vars
- char-escape-string, char-name-string, default-data-readers in core.clj
- Status: 460 done, 131 skip, 112 todo

D1 completed: JVM-skip batch — marked 124 JVM-specific vars as skip.
- Agents (20), Java arrays (35), Refs/STM (10), Proxy/gen-class (11)
- Java compilation/reflection (7), print dispatch (4), streams (3)
- Protocol system (6), internal constructors (7), misc JVM (10+)
- JVM classloader vars (8), class? predicates, bound-fn
- Status: 433 done, 132 skip, 138 todo (was 262)

Phase R completed: require/load/ns system — all 7 tasks done.
- R1: *ns* dynamic var with bootstrap sync
- R2: load-file builtin
- R3: load function with path resolution, IoError in both backends
- R4+R5: require/use upgraded to file-based loading with dedup, :reload
- R6: ns macro already working via core.clj + upgraded require/use
- R7: E2E test — multi-file project with transitive deps, both backends pass

## Handover Notes

Notes that persist across sessions.

- Plan: `.dev/plan/foundation-reset.md` (Phase A-D, with BE inserted)
- **Phase CX plan: `.dev/plan/phase-cx-plan.md`** (read before starting CX tasks)
- Phase A: Completed — all 399 done vars annotated
- Phase BE: Error System Overhaul (complete)
  - BE1: Done — threadlocal + reportError() + showSourceContext()
  - BE2a: Done — core builtins (arithmetic, numeric, predicates); DivisionByZero removed
  - BE2b: Done — collections + sequences; IndexOutOfBounds→IndexError, IllegalState→ValueError
  - BE2c: Done — strings (strings.zig, clj_string.zig); IndexOutOfBounds→IndexError in subsFn
  - BE2d: Done — other builtins (atom, metadata, multimethods, io, system, regex, file_io, ns_ops, misc, eval, var.zig); legacy tags removed
  - BE3a: Done — TreeWalk source location (annotateLocation, file name, message pointer)
  - BE3b: Done — VM source location (lines array in Chunk/FnProto, Compiler tracks current_line, VM annotates from lines[ip-1])
  - BE4: Done — child source preservation on PersistentList/PersistentVector, E2E tests for macro-expanded error positions
  - BE5: Done — source_line/source_column on PersistentList/PersistentVector, formToValue/valueToForm roundtrip, expandMacro stamp (D64)
  - BE6: Done (Part A) — VM column tracking (Chunk.columns, Compiler.current_column, CallFrame.columns)
  - BE6 Part B: Done — arg-level source (ConstantNode, threadlocal arg sources, VM backward scan)
  - BE5/BE6 design: `.dev/notes/be5-be6-design.md` (read before implementing)
  - Architecture: D3a superseded by D63 (threadlocal)
  - Error API: `err.setError(info)`, `err.setErrorFmt(...)`, `err.getLastError()`
  - Display: `reportError()` in main.zig, babashka-style format
- Phase B: Complete — all F## items resolved (B0-B4)
- Phase C: Faithful upstream test porting with CLJW markers (C1-C12 done, C13-C20 saved)
- Phase CX: Known issue resolution (F51, F24, F68, F70-74, F80-83, F86-87, F89, F91, F94)
- **Phase R** (current): require/load/ns system — full file-based loading, see `roadmap.md`
- Phase D (after Phase R): Parallel expansion (new vars + test porting)
- Dynamic binding: var.zig push/pop frame stack, `push-thread-bindings`/`pop-thread-bindings` builtins, `binding` macro, `set!` special form
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Audit tracker: `.dev/status/audit-progress.yaml`
- Beta error reference: `ClojureWasmBeta/src/base/error.zig`, `ClojureWasmBeta/src/main.zig:839-970`
- Beta delay reference: `ClojureWasmBeta/src/lib/core/concurrency.zig`, `ClojureWasmBeta/src/base/value.zig`
- Beta hierarchy reference: `ClojureWasmBeta/src/lib/core/interop.zig`
