# Architecture

This document describes the internal architecture of ClojureWasm.

## Pipeline Overview

ClojureWasm processes Clojure source code through a four-stage pipeline:

```
Source text
    │
    ▼
┌──────────┐
│  Reader   │  Tokenizer → Reader → Form (syntax tree)
└────┬─────┘
     │ Form
     ▼
┌──────────┐
│ Analyzer  │  Form → Node (executable AST)
└────┬─────┘
     │ Node
     ▼
┌──────────────────────────────────┐
│         Dual Backend             │
│                                  │
│  ┌───────────┐  ┌─────────────┐ │
│  │ Compiler   │  │  TreeWalk   │ │
│  │ Node→Chunk │  │  Node→Value │ │
│  └─────┬─────┘  └─────────────┘ │
│        │ Bytecode                │
│        ▼                         │
│  ┌───────────┐                   │
│  │    VM      │                  │
│  │ Chunk→Value│                  │
│  └───────────┘                   │
└──────────────────────────────────┘
```

The **VM** (bytecode compiler + virtual machine) is the default backend.
The **TreeWalk** interpreter serves as the reference implementation for
correctness validation. Both backends produce identical results — verified
by `EvalEngine.compare()` tests.

## Reader

**Files**: `src/reader/reader.zig`, `src/reader/tokenizer.zig`, `src/reader/form.zig`

The reader converts source text into a Form tree (a syntax tree before
semantic analysis). It handles:

- All Clojure literals: integers, floats, BigInt (`42N`), BigDecimal (`42M`),
  Ratio (`1/3`), strings, characters, keywords, symbols, regex (`#"pattern"`)
- Collections: lists `()`, vectors `[]`, maps `{}`, sets `#{}`
- Reader macros: quote `'`, deref `@`, syntax-quote `` ` ``, unquote `~`,
  unquote-splicing `~@`, metadata `^`, fn literal `#()`, var `#'`,
  tagged literals `#inst`, `#uuid`

## Analyzer

**Files**: `src/analyzer/analyzer.zig`, `src/analyzer/node.zig`

The analyzer transforms Forms into Nodes (an executable AST). It resolves
variable bindings, expands macros, and compiles regex patterns at analysis
time. Special forms are dispatched via a comptime string map.

Key responsibilities:
- Local variable resolution (let, fn parameters, loop bindings)
- Macro expansion (requires runtime Env for macro lookup)
- Special form analysis (def, fn, let, if, do, loop, recur, try, etc.)
- Source location tracking for error messages

## Compiler + VM

**Files**: `src/compiler/compiler.zig`, `src/compiler/opcodes.zig`,
`src/compiler/chunk.zig`, `src/vm/vm.zig`

The compiler transforms Nodes into bytecode stored in Chunks. Each
instruction is a fixed 3-byte format: u8 opcode + u16 operand.

### Opcodes

75 opcodes across 10 categories:

| Range       | Category            | Examples                               |
|-------------|---------------------|----------------------------------------|
| 0x00-0x0F   | Constants/Literals  | const_load, nil, true_val, false_val   |
| 0x10-0x1F   | Stack               | pop, dup, pop_under                    |
| 0x20-0x2F   | Local variables     | local_load, local_store                |
| 0x40-0x4F   | Var operations      | var_load, def, defmulti, lazy_seq      |
| 0x50-0x5F   | Control flow        | jump, jump_if_false, jump_back         |
| 0x60-0x6F   | Functions           | call, tail_call, ret, closure          |
| 0x80-0x8F   | Collections         | list_new, vec_new, map_new, set_new    |
| 0xA0-0xAF   | Exceptions          | try_begin, catch_begin, throw_ex       |
| 0xB0-0xBF   | Arithmetic          | add, sub, mul, div, eq, lt, gt         |
| 0xC0-0xDF   | Superinstructions   | add_locals, branch_ne_locals, recur_loop |

Superinstructions (0xC0-0xDF) fuse common multi-instruction sequences into
single opcodes. A peephole optimizer in the compiler detects patterns like
`local_load + local_load + add` and replaces them with `add_locals`.

### VM

The VM is a stack-based machine with:

- **Value stack**: 4096 slots (NaN-boxed 8-byte values)
- **Call frames**: 256 max depth, each tracking IP, base pointer, code, constants
- **Dispatch**: Zig `switch` on opcode (compiles to jump table)
- **GC safe points**: Every 256 instructions (wrapping u8 counter)
- **Exception handling**: Handler stack with scope-aware unwinding

### ARM64 JIT

**File**: `src/vm/jit.zig`

A proof-of-concept JIT compiler for hot integer loops on ARM64.

- Detects hot loops after 64 iterations in `vmRecurLoop`
- Compiles integer comparison + arithmetic + recur patterns to native ARM64
- Deoptimizes to interpreter on non-integer values
- Uses mmap for executable memory with W^X protection (mprotect)
- Registers: x3-x15 for loop variables (unboxed i64), x16 for base pointer

## TreeWalk Interpreter

**File**: `src/evaluator/tree_walk.zig`

The TreeWalk interpreter evaluates Nodes directly without compilation.
It maintains a local binding stack (256 slots) and closure capture.

Primary uses:
- Reference implementation for VM correctness validation
- Bootstrap: core.clj is initially evaluated via TreeWalk
- Macro expansion during analysis

## Value Representation

**File**: `src/runtime/value.zig`

All values are represented as 8-byte NaN-boxed `u64` values. The scheme
uses the NaN space of IEEE 754 doubles to encode non-float types:

```
Float:   raw f64 bits (any bit pattern < 0xFFF9_0000_0000_0000)
Integer: 0xFFF9 | i48 (signed 48-bit integer)
Char:    0xFFFC | u21 (Unicode codepoint)
Const:   0xFFFB | id (0=nil, 1=true, 2=false)
Heap:    tag[16] | subtype[3] | shifted_addr[45]
```

Heap pointers use 4 tag groups (0xFFFA, 0xFFF8, 0xFFFE, 0xFFFF), each
holding 8 subtypes. The address is right-shifted by 3 bits (exploiting
8-byte alignment), giving an effective 48-bit address space.

Heap types include: string, symbol, keyword, list, vector, hash_map,
hash_set, fn_val, atom, lazy_seq, cons, var_ref, protocol, multi_fn,
regex, matcher, big_int, big_decimal, ratio, array, wasm_module, and more.

## Garbage Collector

**File**: `src/runtime/gc.zig`

Mark-sweep collector with free-pool recycling:

1. **Mark phase**: Trace from root set (VM stack, environments, namespaces)
   through all reachable heap values
2. **Sweep phase**: Recycle unreachable allocations to size-specific free
   pools, or free them if pools are full
3. **Trigger**: When `bytes_allocated >= threshold` (initial 1MB, doubles
   after collection if pressure remains)

Free pools are per-(size, alignment) intrusive linked lists. Dead
allocations are cached (up to 4096 blocks per pool) for O(1) reuse.

## Bootstrap

**File**: `src/runtime/bootstrap.zig`

ClojureWasm uses a two-phase bootstrap:

1. **Phase 1**: TreeWalk evaluates core.clj (embedded via `@embedFile`).
   Each top-level form is read, analyzed, and evaluated sequentially.
   Macros registered by `defmacro` are available for subsequent forms.

2. **Phase 2**: Hot functions (transducer factories like `map`, `filter`,
   `comp`, plus `get-in`, `assoc-in`, `update-in`) are recompiled to VM
   bytecode for performance.

Additional namespaces (clojure.test, clojure.set, clojure.walk, etc.)
are similarly embedded and evaluated during bootstrap.

A **bootstrap cache** (pre-compiled at Zig build time) allows startup
in ~4ms by skipping the parse/analyze/eval cycle for core.clj.

## Wasm Runtime

**Files**: `src/wasm/*.zig`

A built-in WebAssembly interpreter supporting 461 opcodes (225 core + 236
SIMD). Clojure code can load and call Wasm modules via the `cljw.wasm`
namespace.

Key components:
- **Module parser**: Decodes Wasm binary format (types, functions, tables,
  memory, globals, imports, exports)
- **Predecoder**: Converts variable-width Wasm bytecode to fixed-width 8-byte
  instructions (`PreInstr`) at load time, with superinstruction fusion
- **VM**: Stack-based interpreter with switch dispatch over predecoded IR
- **WASI**: File I/O, clock, random, args, environ
- **Multi-module linking**: Cross-module function imports
- **SIMD**: v128 type with 236 SIMD opcodes

Performance: The interpreter is ~10-30x slower than wasmtime (JIT compiler)
for compute-heavy modules. This is the fundamental interpreter-vs-JIT gap —
wasmtime compiles Wasm to native machine code via Cranelift, while ClojureWasm
dispatches predecoded instructions one at a time. Module load time is faster
(~4ms vs ~5ms) since no compilation step is needed.

## Regex Engine

**Files**: `src/regex/regex.zig`, `src/regex/matcher.zig`

A built-in regex engine (no external C library dependency). Patterns are
compiled at analysis time into a bytecode representation, then matched
at runtime.

## nREPL Server

**Files**: `src/repl/nrepl.zig`, `src/repl/bencode.zig`

A CIDER-compatible nREPL server supporting 14 operations: eval, load-file,
complete, info, lookup, stacktrace, clone, close, describe, ls-sessions,
interrupt, stdin, eldoc, and ns-list.
