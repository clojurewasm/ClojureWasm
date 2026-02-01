# Task 2.6: Create Compiler (Node -> Bytecode)

## Goal

Create the bytecode Compiler that transforms Node AST into bytecode instructions.
Includes Chunk (instruction container) and FnProto (compiled function) types.

## References

- Beta: `src/compiler/emit.zig` (897L) — full Compiler with all node types
- Beta: `src/compiler/bytecode.zig` — Chunk, FnProto, dumpChunk
- Production: `src/common/bytecode/opcodes.zig` — OpCode, Instruction (Task 2.5)
- Production: `src/common/analyzer/node.zig` — 14 Node variants
- Roadmap: "Compiler-VM contract expressed in types (SS9.1)"

## Plan

### Architecture

Two new files in `src/common/bytecode/`:

1. **`chunk.zig`** — Chunk and FnProto types (data containers)
   - `Chunk`: instruction list + constant pool + emit helpers
   - `FnProto`: compiled function prototype (name, arity, variadic, locals, code, constants)

2. **`compiler.zig`** — Compiler struct (Node -> Bytecode transformation)
   - Compile each Node variant to bytecode
   - Local variable tracking with scope depth
   - Jump patching for if/loop

### Scope: Essential Node variants only

The 14 Node variants in production map to these compiler methods:

| Node variant | Compiler method | Priority           |
| ------------ | --------------- | ------------------ |
| constant     | emitConstant    | P1                 |
| var_ref      | emitVarRef      | P1                 |
| local_ref    | emitLocalRef    | P1                 |
| if_node      | emitIf          | P1                 |
| do_node      | emitDo          | P1                 |
| let_node     | emitLet         | P1                 |
| loop_node    | emitLoop        | P1                 |
| recur_node   | emitRecur       | P1                 |
| fn_node      | emitFn          | P2 (needs FnProto) |
| call_node    | emitCall        | P1                 |
| def_node     | emitDef         | P1                 |
| quote_node   | emitQuote       | P1                 |
| throw_node   | emitThrow       | P2                 |
| try_node     | emitTry         | P2                 |

P1 = implement in this task. P2 = implement in this task but may be simpler stubs.

### Key differences from Beta

1. No threadlocal (D3): `named_fn_offset` becomes a Compiler field
2. No scope_exit opcode initially: use pop instructions instead
3. Simpler local_ref: no `locals_offset` complexity initially
   (fn compilation creates child Compiler, not shared locals)
4. Chunk.addConstant does NOT deep clone (arena-based GC, D2)
5. No letfn, defmulti, defmethod, defprotocol, extend_type, lazy_seq

### TDD steps

#### Part A: Chunk type

1. Red: Test Chunk init/emit/addConstant
2. Green: Implement Chunk
3. Red: Test Chunk jump patching (emitJump/patchJump)
4. Green: Implement jump helpers

#### Part B: FnProto

5. Red: Test FnProto creation
6. Green: Implement FnProto struct

#### Part C: Compiler basics

7. Red: Test compile constant (nil, true, false, int)
8. Green: Implement emitConstant
9. Red: Test compile if_node
10. Green: Implement emitIf
11. Red: Test compile do_node
12. Green: Implement emitDo

#### Part D: Variables and definitions

13. Red: Test compile let_node (local_store/load + scope cleanup)
14. Green: Implement emitLet + addLocal
15. Red: Test compile local_ref
16. Green: Implement emitLocalRef
17. Red: Test compile def_node
18. Green: Implement emitDef
19. Red: Test compile quote_node
20. Green: Implement emitQuote

#### Part E: Functions and calls

21. Red: Test compile call_node
22. Green: Implement emitCall
23. Red: Test compile fn_node (single arity)
24. Green: Implement emitFn + compileArity

#### Part F: Loop/recur + exceptions

25. Red: Test compile loop/recur
26. Green: Implement emitLoop + emitRecur
27. Red: Test compile throw/try
28. Green: Implement emitThrow + emitTry
29. Red: Test compile var_ref
30. Green: Implement emitVarRef

#### Refactor

31. Final file layout cleanup

## Log

### Part A: Chunk type

- Red: Chunk init/emit/addConstant/jump patching tests -> compile error
- Green: Implemented Chunk with emit, emitOp, addConstant, emitJump, patchJump, emitLoop, currentOffset
- Green: FnProto struct with name/arity/variadic/local_count/capture_count/code/constants

### Part B: Compiler

- Red: constant nil/true/false/int compile tests -> compile error (Compiler not defined)
- Green: Compiler struct with compile() dispatch + emitConstant (nil/bool specialization)
- Fixed: Symbol field name `ns` not `namespace`
- Red: if/do/call/def/quote/throw/var_ref/let tests -> const pointer mismatch
- Fixed: Test nodes use `var` to match Node's `*Node` (mutable) pointer fields
- Green: All 14 Node variant emit methods implemented:
  - emitConstant, emitLocalRef, emitIf, emitDo, emitLet, emitLoop, emitRecur
  - emitFn (single arity, placeholder closure), emitCall, emitDef, emitQuote
  - emitThrow, emitTry, emitVarRef
- 13 tests pass covering: constant (nil, true, false, int), if (with/without else),
  do (normal/empty), call, def, quote, throw, let, var_ref
- Refactor: File layout clean (imports -> public types -> private helpers -> tests)
