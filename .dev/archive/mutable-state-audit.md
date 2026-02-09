# Module-Level Mutable State Audit (Phase 24.5.3)

Catalog of all module-level `var` and `threadlocal var` declarations.
28 sites across 11 files. Phase 27 target: move into structs where feasible.

## Non-threadlocal vars (20)

| #  | File                   | Line | Variable              | Purpose                        |
|----|------------------------|------|-----------------------|--------------------------------|
| 1  | main.zig               | 441  | file_read_buf         | Error report file read buffer  |
| 2  | value.zig              | 31   | print_length_var      | *print-length* Var cache       |
| 3  | value.zig              | 32   | print_level_var       | *print-level* Var cache        |
| 4  | var.zig                | 136  | current_frame         | Binding frame stack (GC root)  |
| 5  | keyword_intern.zig     | 12   | table                 | Keyword intern table           |
| 6  | keyword_intern.zig     | 13   | intern_allocator      | Keyword intern allocator       |
| 7  | collections.zig        | 20   | _vec_gen_counter      | Vector COW generation counter  |
| 8  | bootstrap.zig          | 680  | last_thrown_exception | Last thrown exception (catch)  |
| 9  | bootstrap.zig          | 707  | macro_eval_env        | Macro evaluation environment   |
| 10 | builtin/ns_ops.zig     | 21   | load_paths            | Namespace load paths           |
| 11 | builtin/ns_ops.zig     | 25   | loaded_libs           | Loaded libs tracking set       |
| 12 | builtin/ns_ops.zig     | 26   | loaded_libs_allocator | Loaded libs allocator          |
| 13 | builtin/predicates.zig | 17   | current_env           | Current Env ptr for predicates |
| 14 | builtin/io.zig         | 22   | capture_buf           | Output capture buffer          |
| 15 | builtin/io.zig         | 23   | capture_alloc         | Output capture allocator       |
| 16 | builtin/io.zig         | 157  | capture_stack         | Nested capture stack           |
| 17 | builtin/io.zig         | 158  | capture_depth         | Capture nesting depth          |
| 18 | builtin/misc.zig       | 18   | gensym_counter        | gensym unique counter          |
| 19 | builtin/numeric.zig    | 85   | prng                  | Random number generator state  |
| 20 | native/vm/vm.zig       | 83   | active_vm             | Active VM for callback bridge  |

## Threadlocal vars (8)

| # | File      | Line | Variable          | Purpose                         |
|---|-----------|------|-------------------|---------------------------------|
| 1 | value.zig | 33   | print_depth       | Recursive print depth tracker   |
| 2 | value.zig | 34   | print_allocator   | Print-time allocator            |
| 3 | value.zig | 35   | print_readably    | *print-readably* flag           |
| 4 | error.zig | 72   | last_error        | Last error info                 |
| 5 | error.zig | 73   | msg_buf           | Error message buffer            |
| 6 | error.zig | 74   | source_text_cache | Source text for error reporting |
| 7 | error.zig | 75   | source_file_cache | Source file for error reporting |
| 8 | error.zig | 139  | arg_sources       | Argument source location cache  |

## Categories

**Init-once, read-after** (safe): #2, #3, #5, #6, #8, #9, #13
**Monotonic counters** (safe): #7, #18
**Runtime state** (Phase 27 candidates): #4, #10-12, #14-17, #19, #20
**Scratch buffers** (low risk): #1

## Phase 27 Resolution Strategy

Move runtime state into a `RuntimeContext` struct passed through the call chain,
eliminating implicit global coupling. Threadlocal vars may remain for Wasm
single-thread target (no overhead).
