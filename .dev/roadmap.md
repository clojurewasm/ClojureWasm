# ClojureWasm Roadmap

> **Context-efficient reading**: Read Phase Tracker to find the next IN-PROGRESS or PENDING phase.
> Then search `## Phase N:` to jump to that phase's detail section.
> Do NOT read the entire file every session.

### Cross-Platform Gate Policy

Some phases include a **🔒 x86_64 Gate** task. This requires running `zig build test` on
OrbStack Ubuntu x86_64 (Rosetta emulation on Apple Silicon). Gate tasks MUST pass before
moving to the next phase. Lesson from zwasm: ARM64-only development caused painful x86_64
regressions, especially in JIT, GC, and bytecode dispatch.

**Setup**: See `.dev/references/setup_orbstack.md` for one-time VM setup.
**Run tests**: `orb run -m my-ubuntu-amd64 bash -lc "cd /path/to/ClojureWasm && zig build test"`
**When gate fails**: Fix the issue before proceeding. Do NOT defer x86_64 fixes.

### Test & Quality Infrastructure Policy

**Unified test runner** (`test/run_all.sh`): Runs ALL test suites in one command.
CW lesson: test files scattered across directories → missed regressions.
Every commit = `bash test/run_all.sh` on Mac. Gate phases = also on Ubuntu x86_64.
Suites grow incrementally: Phase 1 = Zig unit only → Phase 11+ = upstream + e2e added.

**vars.yaml** (`.dev/status/vars.yaml`): Tracks every `clojure.core` var status.
Fields: `type` (function/macro/special-form/var), `status` (todo/wip/done/skip), `note`.
Update after implementing each var. CW ref: `.dev/status/vars.yaml` (1,293 lines, 90.9% done).
**Gate at Phase 14** (v0.1.0): all non-JVM vars = `done` or justified `skip`.

**Upstream test porting** (`test/upstream/`): Adapted from Clojure JVM tests.
Rules in `.claude/rules/test-porting.md`. Mark ALL changes with `;; CLJW: <reason>`.
NEVER workaround — test fails = implement the feature or mark `;; CLJW: JVM interop`.
CW lesson: 68 files ported, found 11 real bugs through library testing.

**Benchmark infrastructure** (`bench/`): `bench/history.yaml` records every baseline.
Record after EVERY optimization commit with `bash bench/bench.sh record --id=... --reason=...`.
Regression ceiling = 1.2x any single benchmark = STOP and fix before proceeding.
CW lesson: recording was forgotten → regressions went unnoticed. Single `bench.sh` prevents omission.
**flake.nix**: Reproducible dev environment (Zig, hyperfine, yq). Both Mac + Ubuntu.

## Phase Tracker

| Phase | Name                                       | Status      |
|-------|--------------------------------------------|-------------|
| 1     | Value + Reader + Error + Arena GC          | IN-PROGRESS |
| 2     | TreeWalk + Analyzer + Bootstrap Stage 0    | PENDING     |
| 3     | defn + Bootstrap Stage 1-3 + ExceptionInfo | PENDING     |
| 4     | VM + Compiler + Opcodes                    | PENDING     |
| 5     | Collections (HAMT, Vector) + Mark-Sweep GC | PENDING     |
| 6     | LazySeq + concat + higher-order foundation | PENDING     |
| 7     | map/filter/reduce/range + Transducers base | PENDING     |
| 8     | Evaluator.compare() + dual backend verify  | PENDING     |
| 9     | Protocols + Multimethods                   | PENDING     |
| 10    | Namespaces + require + standard libraries  | PENDING     |
| 11    | clojure.test framework                     | PENDING     |
| 12    | Bytecode Cache (serialize + cache_gen)     | PENDING     |
| 13    | VM Optimization: peephole.zig              | PENDING     |
| 14    | CLI + REPL + nREPL + deps.edn + v0.1.0     | PENDING     |
| 15    | Concurrency (future, promise, pmap, agent) | PENDING     |
| 16    | ClojureScript -> JS compiler               | PENDING     |
| 17    | VM Optimization: super_instruction.zig     | PENDING     |
| 18    | Module system + math + C FFI               | PENDING     |
| 19    | module: Wasm FFI (zwasm)                   | PENDING     |
| 20    | module: JIT ARM64                          | PENDING     |

---

## Phase 1: Value + Reader + Error + Arena GC

> Plan ref: `.dev/references/plan_ja.md` §3 (Layer 0), §4.1 (Reader), §8.3
> CW ref: `~/Documents/MyProducts/ClojureWasm/src/runtime/value.zig`, `src/engine/reader/`

**Goal**: Read Clojure source text, produce Form AST. All values are NaN-boxed.
Error infrastructure and Arena GC are built in from Day 1.

**Exit criteria**: `zig build test` passes. Can tokenize+read `(+ 1 2)`, `[1 :a "b"]`, `{:k v}`.

### Tasks

- [x] **1.1** build.zig + build.zig.zon + main.zig skeleton + flake.nix
  - `zig build` / `zig build test` / `zig build run` must work
  - main.zig prints "ClojureWasm" and exits
  - flake.nix: Zig 0.15.2, hyperfine, yq-go (benchmark tooling from Day 1)
  - CW ref: ~/Documents/MyProducts/ClojureWasm/flake.nix
- [x] **1.2** src/runtime/value.zig — NaN Boxing Value type
  - u64 representation: inline nil/true/false/int(i48)/float(f64)
  - Heap pointer encoding: 4 groups x 8 sub-types = 32 slots
  - HeapHeader with mark bit + frozen flag
  - Type check functions: isNil(), isInt(), isFloat(), isString(), etc.
  - CW ref: value.zig. Key diff: 1:1 slot mapping (no slot sharing)
  - Plan ref: plan_ja.md lines 238-267
- [x] **1.3** src/runtime/error.zig — Error infrastructure
  - SourceLocation struct (file, line, column)
  - BuiltinFn signature: fn(args, loc) anyerror!Value
  - Type assertion helpers: expectNumber, expectString, etc.
  - Arity check helpers: checkArity, checkArityMin, checkArityRange
  - Error formatting (ANSI, no I/O dependency)
  - All threadlocal: last_error, call_stack, msg_buf
  - Plan ref: plan_ja.md lines 361-387
- [x] **1.4** src/runtime/gc/arena.zig — Arena GC interface
  - Arena allocator for heap objects
  - gc_mutex: std.Thread.Mutex = .{} (Day 1, unused until threads)
  - suppress_count: u32 (for macro expansion GC suppression)
  - alloc/free interface (Arena mode: alloc only, bulk free)
  - --gc-stress flag preparation (comptime or runtime flag)
  - Plan ref: plan_ja.md lines 292-321
- [x] **1.5** src/runtime/collection/list.zig — PersistentList (cons cell only)
  - Cons struct: first, rest, meta, count
  - cons(), first(), rest(), seq(), count() operations
  - List printing support
  - Plan ref: plan_ja.md lines 269-282
- [x] **1.6** src/runtime/hash.zig — Murmur3 hash
  - Hash function for strings (keywords, symbols)
  - Clojure-compatible hash values
  - CW ref: hash.zig. Clojure ref: ~/Documents/OSS/clojure Murmur3.java
- [x] **1.7** src/runtime/keyword.zig — Keyword interning
  - Global intern table with mutex
  - intern(ns, name) -> *Keyword
  - Namespace-qualified and unqualified keywords
  - Plan ref: plan_ja.md lines 389-400
- [ ] **1.8** src/eval/form.zig — Form structure + SourceLocation
  - Form tagged union: nil, bool, int, float, string, symbol, keyword, list, vector, map
  - Every Form carries SourceLocation
  - Plan ref: plan_ja.md lines 406-414
- [ ] **1.9** src/eval/tokenizer.zig — Lexer
  - Text -> token stream
  - Tokens: lparen, rparen, lbracket, rbracket, lbrace, rbrace, number, string, symbol, keyword, quote, deref, comment, whitespace
  - SourceLocation tracking per token
  - CW ref: ~/Documents/MyProducts/ClojureWasm/src/engine/reader/tokenizer.zig
  - Clojure ref: ~/Documents/OSS/clojure LispReader.java read dispatch
- [ ] **1.10** src/eval/reader.zig — Parser (Phase 1 scope)
  - Token stream -> Form tree
  - Phase 1 scope: nil, true, false, integers, floats, strings (all escapes), keywords (bare + ns-qualified), symbols (bare + ns-qualified), lists (), vectors [], maps {}, comments ;, quote ', ##Inf/##-Inf/##NaN, #_ discard, #! shebang
  - Deferred to Phase 2: syntax-quote, unquote, fn literal, char literal
  - Deferred to Phase 3: metadata, var-quote, reader conditional
  - readString(source, file_name) API from Day 1
  - CW ref: ~/Documents/MyProducts/ClojureWasm/src/engine/reader/reader.zig
  - Plan ref: plan_ja.md lines 416-422
- [ ] **1.11** src/main.zig — Minimal CLI
  - Parse -e flag only
  - Read + print (no eval yet): read form, print it back
  - Verify round-trip: (+ 1 2) -> reads as list -> prints as (+ 1 2)
- [ ] **1.12** 🔒 x86_64 Gate — OrbStack Ubuntu x86_64 setup + `zig build test`
  - One-time: create VM, install Zig 0.15.2 (see `.dev/references/setup_orbstack.md`)
  - NaN boxing bit ops are architecture-sensitive — verify all value.zig tests pass
  - All tests must pass on both ARM64 (Mac) and x86_64 (Ubuntu)

---

## Phase 2: TreeWalk + Analyzer + Bootstrap Stage 0

> Plan ref: `.dev/references/plan_ja.md` §3.5-3.6 (env, dispatch), §4.2-4.5 (analyzer-treewalk), §5 (primitives), §8.4
> CW ref: `src/engine/evaluator/tree_walk.zig`, `src/engine/analyzer/`

**Goal**: Evaluate simple Clojure expressions. `(+ 1 2)` returns `3`.
Bootstrap Stage 0: the ~20 rt/ functions needed before defn exists.

**Exit criteria**: `(let [x 1] (+ x 2))` => `3`. `(if true :yes :no)` => `:yes`.
`(fn* [x] (+ x 1))` works. `(first (cons 1 nil))` => `1`.

### Tasks

- [ ] **2.1** src/runtime/env.zig — Namespace, Var, dynamic bindings
  - Namespace struct with mappings, refers, aliases
  - Var struct with root, meta, flags (dynamic/macro/private)
  - threadlocal current_frame for dynamic bindings
  - Create "rt" and "user" namespaces at init
  - Plan ref: plan_ja.md lines 322-347
- [ ] **2.2** src/runtime/dispatch.zig — vtable + threadlocal state
  - Function pointers: callFn, valueTypeKey, expandMacro
  - threadlocal: current_env, last_thrown_exception
  - All initially undefined, set by Layer 1/2 at startup
  - Plan ref: plan_ja.md lines 348-359
- [ ] **2.3** src/eval/node.zig — Node tagged union
  - Phase 2 nodes: def, if, do, quote, fn, let, loop, recur
  - call_node, local_ref, var_ref, constant
  - Plan ref: plan_ja.md lines 429-458
- [ ] **2.4** src/eval/analyzer.zig — Form -> Node transformation
  - Symbol resolution: local vs var vs special form
  - Macro expansion (via dispatch.expandMacro)
  - Scope tracking (local variable indexing)
  - Special form syntax validation
  - Plan ref: plan_ja.md lines 461-466
- [ ] **2.5** src/eval/backend/tree_walk.zig — AST direct evaluator
  - Evaluate Node tree directly
  - Special forms: def, if, do, fn*, let*, quote, loop*, recur
  - Function calls via dispatch.callFn
  - Error trace: pushFrame/popFrame per form
  - CW ref: tree_walk.zig
  - Plan ref: plan_ja.md lines 501-513
- [ ] **2.6** src/lang/primitive/seq.zig — Sequence primitives
  - rt/first, rt/rest, rt/cons, rt/seq, rt/next
  - Register in rt namespace
  - Plan ref: plan_ja.md line 562
- [ ] **2.7** src/lang/primitive/coll.zig — Collection primitives (minimal)
  - rt/assoc, rt/get, rt/count, rt/conj
  - Minimal: works with lists and array-maps only (no HAMT yet)
  - Plan ref: plan_ja.md line 563
- [ ] **2.8** src/lang/primitive/math.zig — Arithmetic primitives
  - rt/add, rt/sub, rt/mul, rt/div, rt/compare
  - i48 integer arithmetic with overflow to float
  - Clojure ref: ~/Documents/OSS/clojure Numbers.java for semantics
  - Plan ref: plan_ja.md line 564
- [ ] **2.9** src/lang/primitive/string.zig — String primitives
  - rt/str (concatenation), rt/string?
  - Plan ref: plan_ja.md line 565
- [ ] **2.10** src/lang/primitive/pred.zig — Predicate primitives
  - rt/nil?, rt/number?, rt/keyword?, rt/fn?, rt/coll?, rt/seq?
  - Plan ref: plan_ja.md line 566
- [ ] **2.11** src/lang/primitive/io.zig — IO primitives
  - rt/println, rt/pr, rt/prn
  - Uses std.Io.Writer (see zig_tips.md)
  - Plan ref: plan_ja.md line 567
- [ ] **2.12** src/lang/primitive/core.zig — Core primitives
  - rt/apply, rt/type, rt/identical?
  - Plan ref: plan_ja.md line 561
- [ ] **2.13** src/lang/primitive.zig — Registration entry point
  - registerAll(env) calls all primitive/*.register(rt_ns)
  - Plan ref: plan_ja.md lines 577-589
- [ ] **2.14** src/lang/macro_transforms.zig — defmacro transform
  - Zig-level macro: defmacro sets .macro flag on Var
  - Cannot be a .clj macro (needs .setMacro() which is Java)
  - Plan ref: plan_ja.md lines 613-621
- [ ] **2.15** src/lang/bootstrap.zig — Stage 0 execution
  - Load and eval core.clj Stage 0 (~50 lines)
  - Pre-defn functions: list, cons, first, rest, seq, nil?, =
  - Plan ref: plan_ja.md lines 601-604
- [ ] **2.16** src/lang/clj/clojure/core.clj — Stage 0 content
  - ~50 lines of pre-defn core definitions
  - Upstream adapted: RT/xxx -> rt/xxx
  - Clojure ref: ~/Documents/OSS/clojure/src/clj/clojure/core.clj lines 1-285
  - Plan ref: plan_ja.md lines 591-599
- [ ] **2.17** Update main.zig — Add eval to read-print
  - -e '(+ 1 2)' now evaluates and prints result
  - Bootstrap runs at startup
- [ ] **2.18** test/run_all.sh — Unified test runner
  - Phase 2 scope: `zig build test` only (grows as suites are added)
  - Single entry point: `bash test/run_all.sh` — all commits use this
  - CW lesson: scattered test scripts → missed regressions
  - CW ref: ~/Documents/MyProducts/ClojureWasm/test/run_all.sh
- [ ] **2.19** .dev/status/vars.yaml — Initial var tracking
  - Generate skeleton from upstream core.clj (all vars listed as `todo`)
  - Mark Phase 2 rt/ primitives as `done`
  - Script: .dev/scripts/generate_vars_yaml.clj (CW ref: same path)
  - CW ref: ~/Documents/MyProducts/ClojureWasm/.dev/status/vars.yaml
- [ ] **2.20** scripts/zone_check.sh — Zone dependency checker
  - Verify no upward imports (runtime/ ← eval/ etc.)
  - Used as commit gate (plan_ja.md §11.2)
- [ ] **2.21** scripts/coverage.sh — vars.yaml coverage report
  - Reports done/wip/todo/skip counts and percentages

---

## Phase 3: defn + Bootstrap Stage 1-3 + ExceptionInfo

> Plan ref: `.dev/references/plan_ja.md` §5.4 (bootstrap stages), §3.7 (error)
> Clojure ref: `~/Documents/OSS/clojure/src/clj/clojure/core.clj` lines 1-600

**Goal**: `defn` works. core.clj through Stage 3 (~200 lines). `ex-info`/`try`/`catch` work.

**Exit criteria**: `(defn f [x] (+ x 1)) (f 2)` => `3`.
`(try (/ 1 0) (catch Exception e :caught))` => `:caught`.

### Tasks

- [ ] **3.1** Reader Phase 2 additions — syntax-quote (` ~ ~@), unquote, splicing-unquote, fn literal #(), char literal \a \newline \space. Plan ref: plan_ja.md line 419
- [ ] **3.2** Analyzer: syntax-quote expansion — ` expands to (seq (concat ...)) form. Gensym generation for auto-gensym (x#)
- [ ] **3.3** Bootstrap Stage 1-2 — Stage 1: second, ffirst, last, butlast, sigs. Stage 2: concat, apply, list* (needed for syntax-quote). Plan ref: plan_ja.md lines 605-606
- [ ] **3.4** Bootstrap Stage 3 — defn (TURNING POINT) — defn macro defined in core.clj (upstream line 285). After this, all further definitions use defn. Plan ref: plan_ja.md line 607
- [ ] **3.5** src/lang/primitive/meta.zig — rt/meta, rt/with-meta, rt/vary-meta, rt/alter-meta!. Plan ref: plan_ja.md line 568
- [ ] **3.6** src/lang/primitive/error.zig — rt/ex-info, rt/ex-message, rt/ex-data, rt/ex-cause. ExceptionInfo as Value heap type. Plan ref: plan_ja.md line 572
- [ ] **3.7** Analyzer + TreeWalk: try/catch/finally/throw — throw_node, try_node in Node union. Plan ref: plan_ja.md lines 446-448
- [ ] **3.8** Reader Phase 3 additions — ^metadata syntax, #'var-quote. Plan ref: plan_ja.md line 420
- [ ] **3.9** .claude/rules/test-porting.md — Upstream test adaptation rules
  - CLJW: marker format, NEVER workaround, implement-or-skip discipline
  - CW ref: ~/Documents/MyProducts/ClojureWasm/.claude/rules/test-porting.md
  - Created now so all future test porting follows consistent rules
- [ ] **3.10** vars.yaml update — Mark Phase 3 vars as `done` (defn, meta, error)

---

## Phase 4: VM + Compiler + Opcodes

> Plan ref: `.dev/references/plan_ja.md` §4.3-4.4 (compiler, VM), §4.6 (opcode)
> CW ref: `~/Documents/MyProducts/ClojureWasm/src/engine/vm/`, `src/engine/compiler/`

**Goal**: Bytecode compiler + stack-based VM. Same results as TreeWalk.

**Exit criteria**: All existing TreeWalk tests also pass on VM backend.
`cljw -e '(+ 1 2)'` uses VM by default, `--tree-walk` flag for TreeWalk.

### Tasks

- [ ] **4.1** src/eval/backend/opcode.zig — Opcode enum + metadata. 39 Phase 1 opcodes (see plan §4.3). 4-byte instruction format: packed struct { op: u8, flags: u8, operand: u16 }. Plan ref: plan_ja.md lines 467-495
- [ ] **4.2** src/eval/backend/compiler.zig — Bytecode compiler. Node -> Bytecode. Constant pool management. Local variable slot allocation. Jump patching. CW ref: compiler.zig
- [ ] **4.3** src/eval/backend/vm.zig — Stack-based VM. Instruction dispatch loop (switch on opcode). Value stack, call frames. Exception handling. Target: ~1,500 LOC. CW ref: vm.zig. Plan ref: plan_ja.md lines 497-499
- [ ] **4.4** Update main.zig — VM as default backend. Flag --tree-walk for TreeWalk
- [ ] **4.5** Verify: all tests pass on both backends. Fix any divergences
- [ ] **4.6** vars.yaml update — Mark Phase 4 progress
- [ ] **4.7** 🔒 x86_64 Gate — `zig build test` on OrbStack Ubuntu
  - VM opcode dispatch (switch on u8) can behave differently under Rosetta
  - Bytecode layout / packed struct alignment may differ
  - zwasm lesson: opcode dispatch bugs surfaced only on x86_64

---

## Phase 5: Collections (HAMT, Vector) + Mark-Sweep GC

> Plan ref: `.dev/references/plan_ja.md` §3.3 (hamt, vector), §3.4 (gc), §3.2 (collections)
> CW ref: `src/runtime/hamt.zig`, `src/runtime/persistent_vector.zig`, `src/runtime/gc.zig` (CW paths, flat)
> Clojure ref: `~/Documents/OSS/clojure` PersistentHashMap.java, PersistentVector.java

**Goal**: Full persistent data structures. GC handles transient temporaries.

**Exit criteria**: `(assoc {:a 1} :b 2)` works. `(conj [1 2] 3)` works.
`(= (hash-map :a 1 :b 2) {:a 1 :b 2})` => `true`. GC stress test passes.

### Tasks

- [ ] **5.1** src/runtime/collection/hamt.zig — PersistentHashMap + PersistentHashSet. HAMT: BitmapNode, CollisionNode. @popCount. ArrayMap -> HashMap auto-promotion (threshold 8). Plan ref: plan_ja.md lines 284-290
- [ ] **5.2** src/runtime/collection/vector.zig — PersistentVector. 32-way trie + tail optimization. conj, nth, assocN, pop. Plan ref: plan_ja.md lines 284-290
- [ ] **5.3** Extend collection/list.zig — ArrayMap for small maps (<=8 entries). Auto-promote to HashMap above threshold. Plan ref: plan_ja.md line 282
- [ ] **5.4** Reader Phase 5 additions — set #{}, deref @, regex #"", namespaced map #:ns{}, hex/octal/radix numbers. Plan ref: plan_ja.md line 421
- [ ] **5.5** src/lang/primitive/atom.zig — rt/atom, rt/deref, rt/swap!, rt/reset!, rt/compare-and-set!. Atom root uses std.atomic.Value(u64). Plan ref: plan_ja.md line 570
- [ ] **5.6** src/runtime/gc/mark_sweep.zig — Mark-Sweep GC. Tri-color marking. HeapHeader mark bit. Free Pool. Threshold adaptation. Plan ref: plan_ja.md lines 292-321
- [ ] **5.7** src/runtime/gc/roots.zig — Root set + type-specific mark traversal. Plan ref: plan_ja.md lines 315-321
- [ ] **5.8** GC stress testing — --gc-stress flag. Verify no root tracking leaks. Test CW D100 leak scenarios
- [ ] **5.9** 🔒 x86_64 Gate — `zig build test` on OrbStack Ubuntu
  - Mark-Sweep GC pointer traversal / heap layout under x86_64
  - HAMT bit operations (@popCount, bitmap indexing) — verify identical behavior
  - GC stress test must also pass on x86_64

---

## Phase 6: LazySeq + concat + higher-order foundation

> Plan ref: `.dev/references/plan_ja.md` §5.1 (prim_lazy)
> Clojure ref: `~/Documents/OSS/clojure/src/clj/clojure/core.clj` LazySeq, concat

**Goal**: Lazy sequences work. `(take 5 (range))` returns `(0 1 2 3 4)`.

**Exit criteria**: `(take 10 (iterate inc 0))` works. `(concat [1 2] [3 4])` => `(1 2 3 4)`.

### Tasks

- [ ] **6.1** src/lang/primitive/lazy.zig — rt/lazy-seq-thunk, rt/realized?. LazySeq heap type. Thread-safe realization (CAS). Plan ref: plan_ja.md line 574
- [ ] **6.2** Analyzer + both backends: lazy-seq special form handling. lazy-seq_node in Node union. Compiler emits closure for thunk body
- [ ] **6.3** core.clj: concat, mapcat, take, drop, take-while, drop-while. Upstream adapted. Clojure ref: ~/Documents/OSS/clojure/src/clj/clojure/core.clj
- [ ] **6.4** core.clj: iterate, repeat, repeatedly, cycle. Infinite sequence generators

---

## Phase 7: map/filter/reduce/range + Transducers base

> Clojure ref: `~/Documents/OSS/clojure/src/clj/clojure/core.clj` map, filter, reduce

**Goal**: Core functional programming. `(map inc [1 2 3])` => `(2 3 4)`.

**Exit criteria**: `(reduce + [1 2 3])` => `6`. `(filter odd? (range 10))` works.
`(into [] (map inc) [1 2 3])` => `[2 3 4]` (transducer form).

### Tasks

- [ ] **7.1** core.clj: map, filter, remove, keep, keep-indexed. Multi-arity (transducer + sequence) forms. Upstream adapted
- [ ] **7.2** core.clj: reduce, reduce-kv, into, transduce. Clojure ref: core.clj reduce + IReduce consideration
- [ ] **7.3** core.clj: range, partition, partition-by, partition-all
- [ ] **7.4** core.clj: sort, sort-by, group-by, frequencies
- [ ] **7.5** core.clj: comp, partial, juxt, complement, every-pred, some-fn
- [ ] **7.6** core.clj: for, doseq (macro). List comprehension + side-effect loop

---

## Phase 8: Evaluator.compare() + dual backend verify

> Plan ref: `.dev/references/plan_ja.md` §4.7 (Evaluator)

**Goal**: Verify VM and TreeWalk produce identical results for all tests.

**Exit criteria**: `Evaluator.compare()` runs all tests. Zero divergences.

### Tasks

- [ ] **8.1** src/eval/backend/evaluator.zig — compare(form): run on both backends, assert equal. Plan ref: plan_ja.md lines 537-548
- [ ] **8.2** Add Evaluator test mode — flag to select: vm-only, treewalk-only, compare
- [ ] **8.3** Fix any divergences found — VM/TreeWalk differences are bugs
- [ ] **8.4** Benchmark infrastructure setup
  - bench/bench.sh — single entry point (run / record / compare subcommands)
  - bench/history.yaml — baseline recording (CW ref: bench/history.yaml)
  - bench/compare.yaml — cross-language comparison snapshot (not history)
  - bench/suite/NN_name/ structure: meta.yaml + bench.clj per benchmark
  - Initial suite: fib_recursive, fib_loop, map_filter_reduce, vector_ops
  - Suite should be complete before first recording
  - CW ref: ~/Documents/MyProducts/ClojureWasm/bench/ (31 benchmarks)
- [ ] **8.5** Record baseline — `bash bench/bench.sh record --id="8.0" --reason="Phase 8 baseline"`
  - First official benchmark snapshot. All future optimizations measured against this
- [ ] **8.6** vars.yaml update — Mark Phase 5-8 vars as `done`
- [ ] **8.7** 🔒 x86_64 Gate — Evaluator.compare() + benchmarks on OrbStack Ubuntu
  - Full dual-backend verification on x86_64
  - Run benchmarks on x86_64 too — record as separate column in history.yaml
  - This is the last gate before high-level phases — all low-level code must work

---

## Phase 9: Protocols + Multimethods

> Plan ref: `.dev/references/plan_ja.md` §5.1 (prim_protocol)
> Clojure ref: `~/Documents/OSS/clojure/src/clj/clojure/core.clj` defprotocol, extend-type

**Goal**: `defprotocol`, `extend-type`, `defmulti`/`defmethod` work.

**Exit criteria**: Can define a protocol, extend it, dispatch on it. Multimethods work.

### Tasks

- [ ] **9.1** src/lang/primitive/protocol.zig — defprotocol, extend-type, satisfies?, extends?. String-based type keys. Monomorphic inline cache with generation counter. Plan ref: plan_ja.md line 571
- [ ] **9.2** Analyzer + both backends: reify, defprotocol, extend-type nodes
- [ ] **9.3** Multimethod support — defmulti, defmethod, prefer-method. 2-level cache. isa? hierarchy
- [ ] **9.4** core.clj: protocol-based functions

---

## Phase 10: Namespaces + require + standard libraries

> Plan ref: `.dev/references/plan_ja.md` §5.4 (bootstrap stages 5-6), §5.1 (prim_ns)
> Clojure ref: `~/Documents/OSS/clojure/src/clj/clojure/string.clj`, etc.

**Goal**: `(require '[clojure.string :as str])` works.

**Exit criteria**: `(clojure.string/join ", " [1 2 3])` => `"1, 2, 3"`.

### Tasks

- [ ] **10.1** src/lang/primitive/ns.zig — rt/in-ns, rt/require, rt/refer, rt/alias, rt/all-ns. Plan ref: plan_ja.md line 569
- [ ] **10.2** src/lang/ns_loader.zig — @embedFile for bundled .clj. File path resolution for user files
- [ ] **10.3** Analyzer: ns macro handling — macro_transforms.zig handles ns expansion
- [ ] **10.4** src/lang/clj/clojure/string.clj — Upstream adapted. Clojure ref: ~/Documents/OSS/clojure/src/clj/clojure/string.clj
- [ ] **10.5** src/lang/clj/clojure/set.clj — Upstream adapted. Clojure ref: ~/Documents/OSS/clojure/src/clj/clojure/set.clj
- [ ] **10.6** src/lang/clj/clojure/walk.clj — Upstream adapted. Clojure ref: ~/Documents/OSS/clojure/src/clj/clojure/walk.clj
- [ ] **10.7** Bootstrap Stage 4 completion — remaining ~570 defn/defmacro from core.clj. Plan ref: plan_ja.md line 608

---

## Phase 11: clojure.test framework

> Clojure ref: `~/Documents/OSS/clojure/src/clj/clojure/test.clj`

**Goal**: `(clojure.test/run-tests)` works.

**Exit criteria**: `(deftest my-test (is (= 1 1)))` passes. `run-tests` reports results.

### Tasks

- [ ] **11.1** src/lang/clj/clojure/test.clj — deftest, testing, is, are macros. Upstream adapted. Clojure ref: ~/Documents/OSS/clojure/src/clj/clojure/test.clj
- [ ] **11.2** Upstream test porting — Phase 1 batch
  - Port from ~/Documents/OSS/clojure/test/clojure/test_clojure/
  - Priority: data_structures.clj, sequences.clj, numbers.clj, reader.clj, string.clj
  - Follow .claude/rules/test-porting.md strictly: CLJW: markers, no workarounds
  - Place in test/upstream/. Header: source file, upstream lines, CLJW marker count
  - Failures = implementation bugs → fix before proceeding (separate commits)
- [ ] **11.3** Upstream test porting — Phase 2 batch
  - evaluation.clj, special.clj, other_functions.clj, vars.clj, protocols.clj
  - These may reveal gaps in Phase 9 (protocols) — fix as needed
- [ ] **11.4** vars.yaml audit — Cross-check against upstream test coverage
  - Any var tested upstream but status=todo → either implement or justify skip
  - Update DIFFERENCES.md (upstream compatibility documentation)
- [ ] **11.5** test/e2e/run_e2e.sh — E2E test runner for CLI flags, file execution, error output
- [ ] **11.6** Update test/run_all.sh — Add upstream tests + e2e to unified runner
  - Suites: Zig unit → Clojure upstream → E2E
  - Single `bash test/run_all.sh` runs everything

---

## Phase 12: Bytecode Cache (serialize + cache_gen)

> Plan ref: `.dev/references/plan_ja.md` §4.6 (serialize, cache_gen)

**Goal**: core.clj compiles once at build time, loads instantly at runtime.

**Exit criteria**: Startup time drops significantly. Cache embedded via @embedFile.

### Tasks

- [ ] **12.1** src/eval/cache/serialize.zig — Bytecode serialization (CWNC format). Constant pool, instruction stream, metadata
- [ ] **12.2** src/eval/cache/generate.zig — Build-time cache generation. @embedFile the serialized cache
- [ ] **12.3** Bootstrap: load from cache at startup. Fallback to source eval if cache version mismatch

---

## Phase 13: VM Optimization: peephole.zig

> Plan ref: `.dev/references/plan_ja.md` §4.6, §10 (optimization strategy)

**Goal**: Basic bytecode optimizations. Measurable speedup.

**Exit criteria**: Peephole pass runs after compilation. All tests pass. Benchmark shows improvement.

### Tasks

- [ ] **13.1** src/eval/optimize/peephole.zig — load+pop elimination, jump threading, constant folding. Plan ref: plan_ja.md lines 515-535
- [ ] **13.2** Compiler integration — optimizer as post-pass. comptime optimize_level
- [ ] **13.3** Record pre-optimization baseline — `bash bench/bench.sh record --id="13.0" --reason="Pre-peephole"`
- [ ] **13.4** Record post-optimization — `bash bench/bench.sh record --id="13.1" --reason="Peephole pass"`
  - Compare against 13.0
  - CW lesson: recording was forgotten after optimizations → regressions went unnoticed
  - **Rule**: Every optimization commit = benchmark record. No exceptions

---

## Phase 14: CLI + REPL + nREPL + deps.edn + v0.1.0

> Plan ref: `.dev/references/plan_ja.md` §6 (Layer 3), §9 (UX design)
> CW ref: `src/app/` for CLI/REPL, `src/app/nrepl/` for nREPL

**Goal**: Full user-facing application. v0.1.0 release.

**Exit criteria**: `cljw` REPL works. `cljw file.clj` runs files. `cljw --nrepl-server` starts nREPL.

### Tasks

- [ ] **14.1** src/app/cli.zig — CLI argument parser. Plan ref: plan_ja.md lines 626-643
  - Commands: `cljw` (REPL), `cljw file.clj` (file exec), `cljw js src/ -o dist/` (CLJS), `cljw build -o myapp src/main.clj` (single binary)
  - Flags: `-e EXPR` (inline eval), `-i FILE` (load before eval), `-m NS` (run -main), `-r` (REPL after load), `-P` (deps resolve), `-h` (help), `--version`
  - nREPL: `--nrepl-server`, `--port PORT`
  - Backend: `--tree-walk` (TreeWalk instead of VM)
  - Combinable: `cljw -i a.clj -e '...' b.clj` (sequential, shared state)
- [ ] **14.2** src/app/runner.zig — Error output formatting (stderr, ANSI colors)
- [ ] **14.3** src/app/repl/repl.zig — NS-aware prompt, multi-line, *1/*2/*3/*e, ANSI. Plan ref: plan_ja.md lines 650-654
- [ ] **14.4** src/app/repl/line_editor.zig — history, Emacs keybindings, Tab completion. CW ref: line_editor.zig
- [ ] **14.5** src/app/repl/bencode.zig — nREPL wire protocol
- [ ] **14.6** src/app/repl/nrepl.zig — TCP server, .nrepl-port, 14 operations. CW ref: nrepl.zig. Plan ref: plan_ja.md lines 656-678
- [ ] **14.7** src/app/deps.zig — deps.edn parser (:paths, :deps, :aliases). Plan ref: plan_ja.md lines 691-694
- [ ] **14.8** src/app/builder.zig — Single binary (CWNB format). Plan ref: plan_ja.md lines 685-689
- [ ] **14.9** 📋 vars.yaml OK Gate — All non-JVM vars verified
  - Every clojure.core var: `done` or justified `skip` (with note)
  - No `todo` or `wip` remaining for vars that should work
  - Cross-check: upstream tests pass for all `done` vars
  - Update DIFFERENCES.md with final compatibility summary
- [ ] **14.10** 📊 Benchmark v0.1.0 baseline
  - Record: `bash bench/bench.sh record --id="v0.1.0" --reason="v0.1.0 release"`
  - Run on both Mac ARM64 + Ubuntu x86_64
  - Cross-language comparison: `bash bench/bench.sh compare --lang=cw,c,zig,java,python,node`
- [ ] **14.11** 🔒 x86_64 Gate — Full test suite + CLI on OrbStack Ubuntu
  - v0.1.0 release gate: `bash test/run_all.sh` on x86_64
  - REPL, nREPL, file execution, deps.edn — all must work
  - Benchmarks on x86_64 — record in history.yaml
- [ ] **14.12** v0.1.0 release — README, version tagging, full test suite

---

## Phase 15: Concurrency (future, promise, pmap, agent)

> Clojure ref: `~/Documents/OSS/clojure/src/clj/clojure/core.clj` future, promise, pmap

**Goal**: Concurrency primitives using Zig's thread support.

**Exit criteria**: `(deref (future (+ 1 2)))` => `3`. `pmap` parallelizes work.

### Tasks

- [ ] **15.1** future, promise, deliver
- [ ] **15.2** pmap, pcalls, pvalues
- [ ] **15.3** agent, send, send-off, await
- [ ] **15.4** Thread safety verification under concurrent load
- [ ] **15.5** 🔒 x86_64 Gate — Concurrency tests on OrbStack Ubuntu
  - Thread scheduling, mutex behavior differ under Rosetta emulation
  - future/promise/pmap must work correctly under x86_64
  - Run under --gc-stress + concurrency for race condition detection

---

## Phase 16: ClojureScript -> JS compiler

> CLJS ref: `~/Documents/OSS/clojurescript/src/main/clojure/cljs/`
> Kiso ref: `~/Kiso/` (TypeScript CLJS->JS reference)

**Goal**: `cljw js src/ -o dist/` compiles ClojureScript to JavaScript.

**Exit criteria**: Simple CLJS files compile to working JS.

### Tasks

- [ ] **16.1** src/lang/clj/cljs/analyzer.clj — CLJS analyzer
- [ ] **16.2** src/lang/clj/cljs/emitter.clj — JS code generation
- [ ] **16.3** src/lang/clj/cljs/env.clj — Compilation environment
- [ ] **16.4** src/lang/clj/cljs/resolver.clj — NS resolution for CLJS
- [ ] **16.5** src/lang/clj/cljs/core.cljs — CLJS core macros
- [ ] **16.6** Integration: cljw js subcommand

---

## Phase 17: VM Optimization: super_instruction.zig

> Plan ref: `.dev/references/plan_ja.md` §10 (optimization strategy)
> CW ref: 16 super-instructions, +15-20% VM speed

**Goal**: Fused super-instructions for common opcode sequences.

**Exit criteria**: Measurable VM speedup. All tests pass.

### Tasks

- [ ] **17.1** Record pre-optimization baseline — `bash bench/bench.sh record --id="17.0" --reason="Pre-super-instruction"`
- [ ] **17.2** src/eval/optimize/super_instruction.zig — Identify frequent opcode pairs/triples, fuse into single dispatch
- [ ] **17.3** Opcode enum extension — add fused opcodes, VM dispatch
- [ ] **17.4** Record post-optimization — `bash bench/bench.sh record --id="17.1" --reason="Super-instructions"`
  - Compare against 17.0. Target: +15-20% VM speed (CW achieved this)
  - Run on both Mac + Ubuntu x86_64

---

## Phase 18: Module System + math + C FFI

> Plan ref: `.dev/references/plan_ja.md` §7 (module system)

**Goal**: Module infrastructure + default math module + C FFI.

**Exit criteria**: `(math/sin 1.0)` works. `(cffi/call "strlen" :long [:string] "hello")` => `5`.

### Tasks

- [ ] **18.1** src/runtime/module.zig — ModuleDef interface
  - Registration API for modules. Core code never imports modules/
  - Plan ref: plan_ja.md §7.1
- [ ] **18.2** modules/math/module.zig + modules/math/builtins.zig — Default math module
  - 45 math functions (sin, cos, tan, abs, ceil, floor, etc.)
  - Default-enabled (`-Dmath=false` to disable)
  - Plan ref: plan_ja.md §7.2
- [ ] **18.3** build.zig: Module comptime flags (-Dmath, -Dc-ffi, -Dwasm)
- [ ] **18.4** modules/c_ffi/module.zig — ModuleDef
- [ ] **18.5** modules/c_ffi/exports.zig — C ABI export
- [ ] **18.6** build.zig: -Dc-ffi=true flag

---

## Phase 19: module: Wasm FFI (zwasm)

> zwasm ref: `~/Documents/MyProducts/zwasm/`

**Goal**: Load and execute Wasm modules from Clojure.

**Exit criteria**: Can load a .wasm file, call exported functions.

### Tasks

- [ ] **19.1** modules/wasm/module.zig — ModuleDef
- [ ] **19.2** modules/wasm/builtins.zig — Wasm operations
- [ ] **19.3** modules/wasm/wasm.clj — cljw.wasm namespace
- [ ] **19.4** build.zig: -Dwasm=true flag + zwasm dependency

---

## Phase 20: module: JIT ARM64

> Plan ref: `.dev/references/plan_ja.md` §10 (optimization strategy)
> zwasm ref: `~/Documents/MyProducts/zwasm/.claude/rules/jit-check.md`
> CW ref: JIT PoC results (10.3x on tight loops)

**Goal**: JIT-compile hot loops to ARM64 native code.

**Exit criteria**: Hot loop benchmark shows significant speedup (target: 5x+).

### Tasks

- [ ] **20.1** src/eval/optimize/jit_arm64.zig — Hotness counter, ARM64 emission, mmap
- [ ] **20.2** VM integration — call counter, JIT threshold, interpreter fallback
- [ ] **20.3** Benchmark: JIT vs interpreter vs native C
- [ ] **20.4** 🔒 x86_64 Gate — Interpreter fallback on OrbStack Ubuntu
  - JIT ARM64 is ARM64-only by design — x86_64 must fall back to interpreter
  - Verify: all tests pass on x86_64 with JIT disabled (comptime or runtime flag)
  - zwasm lesson: JIT ARM64 bugs caused x86_64 test failures when fallback wasn't clean
- [ ] **20.5** src/eval/optimize/jit_x86_64.zig — x86_64 JIT (stretch goal)
  - System V AMD64 ABI (rdi, rsi, rdx, rcx, r8, r9)
  - Variable-length encoding vs ARM64 fixed-width — key architecture difference
  - zwasm ref: ~/Documents/MyProducts/zwasm/src/x86.zig
