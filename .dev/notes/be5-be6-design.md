# BE5/BE6 Design: Source Location Precision

Persistent design document for error source location improvements.
Referenced from memo.md. Read before implementing BE5 or BE6.

## Problem Statement

Two separate issues cause imprecise error locations:

### Problem 1: Macro expansion loses source info

```
(defn add [x y] (+ x y))  ; line 1
(add 1 "hello")            ; line 2 — error shows NO location
```

Pipeline: `Form(line=1) → formToValue → Value(no source) → macro → Value → valueToForm → Form(line=0)`

Root cause: `Value` has no source info field. `macro.zig:valueToForm()` creates
Forms with `line=0, column=0` because there is nothing to restore from.

### Problem 2: Builtins point to call site, not problematic argument

```
(+ 1 (/ 10 0))
     ^           ← TreeWalk: col 5, the (/ ...) call
^                ← VM: col 0, the (+ ...) call
                 ← Desired: col 13, the `0` literal
```

Root cause: Builtins receive `Value`s with no source info. Errors are annotated
at the call expression level by the evaluator's error wrapper, not at the
specific argument that caused the error.

---

## BE5: Macro Expansion Source Preservation

### Design: Source fields on collection types

Add source tracking fields to `PersistentList` and `PersistentVector`:

```zig
// collections.zig
pub const PersistentList = struct {
    items: []const Value,
    source_line: u32 = 0,
    source_column: u16 = 0,  // u16 matches Form.column
};

pub const PersistentVector = struct {
    items: []const Value,
    source_line: u32 = 0,
    source_column: u16 = 0,
};
```

### Changes

1. **collections.zig**: Add `source_line`/`source_column` to PersistentList and PersistentVector
2. **macro.zig `formToValue()`**: When converting list/vector Forms, copy `form.line` and `form.column` to the collection's source fields
3. **macro.zig `valueToForm()`**: When converting list/vector Values back to Forms, read source fields and set `form.line`/`form.column`
4. **analyzer.zig `expandMacro()`**: After `valueToForm`, if top-level expanded form has `line=0`, stamp the original macro call's `form.line`/`form.column`

### Why this works

For `(defn add [x y] (+ x y))`:
- Reader parses: `add`(line=1,col=6), `[x y]`(line=1,col=10), `(+ x y)`(line=1,col=16)
- `formToValue`: `[x y]` → PersistentVector with source_line=1,source_column=10
- `formToValue`: `(+ x y)` → PersistentList with source_line=1,source_column=16
- Macro executes, rearranges Values (source fields travel with the collections)
- `valueToForm`: PersistentVector → Form(line=1,col=10) ← **restored!**
- `valueToForm`: PersistentList → Form(line=1,col=16) ← **restored!**
- Top-level `(def add (fn ...))` → Form(line=0) → stamped with macro call's line=1,col=0

### Principle

Same approach as JVM Clojure (metadata with `:line`/:column` on collections),
but lighter: dedicated fields instead of full metadata map.

### Impact scope

- PersistentList/PersistentVector: +6 bytes per instance (u32+u16, default 0)
- All code creating lists/vectors: no change needed (defaults to 0)
- Only formToValue/valueToForm need explicit source field handling

---

## BE6: Argument-Level Error Source Annotation

### Design: Threadlocal arg source tracking + column debug info

Two sub-parts:

#### Part A: Column tracking in VM debug info

Add `columns` array parallel to `lines` in Chunk/FnProto/CallFrame.
Compiler sets `current_column` from `node.source().column`.
VM's `execute()` annotates errors with both line and column.

In emitCall/emitVariadicArith: save/restore current_line/current_column
around argument compilation so operation opcodes (add, div, call) get
the call-site source, not the last argument's source.

#### Part B: Threadlocal arg source for builtins

```zig
// error.zig
threadlocal var arg_sources: [8]SourceLocation = .{.{}} ** 8;
threadlocal var arg_source_count: u8 = 0;

pub fn saveArgSources(sources: []const SourceLocation) void { ... }
pub fn getArgSource(idx: u8) SourceLocation { ... }
```

**TreeWalk**: Before calling builtins, save each arg's Node source:
```zig
for (args, 0..) |arg, i| {
    const val = try self.run(arg);
    err_mod.saveArgSource(@intCast(i), nodeSource(arg));
    evaluated[i] = val;
}
```

**VM**: Before binary ops, save source from debug info:
```zig
// The instruction before the binary op loaded the 2nd operand
// (compiler always emits: [1st operand instrs] [2nd operand instrs] [binary op])
fn vmBinaryArith(self: *VM, op: ArithOp) VMError!void {
    const frame = &self.frames[self.frame_count - 1];
    if (frame.lines.len > 0 and frame.ip >= 2) {
        // ip-1 = binary op (current), ip-2 = last instr of 2nd operand
        err_mod.saveArgSource(1, .{
            .line = frame.lines[frame.ip - 2],
            .column = frame.columns[frame.ip - 2],
            .file = err_mod.getSourceFile(),
        });
    }
    // ... execute binary op
}
```

**Builtins**: Use `getArgSource(idx)` when setting errors:
```zig
// arithmetic.zig — binaryDiv
if (b is zero) {
    return err.setError(.{
        .kind = .arithmetic_error,
        .phase = .eval,
        .message = "Divide by zero",
        .location = err.getArgSource(1),  // divisor is arg[1]
    });
}

// binaryArith — type check
if (a is not numeric) {
    return err.setError(.{ ... .location = err.getArgSource(0) });
}
if (b is not numeric) {
    return err.setError(.{ ... .location = err.getArgSource(1) });
}
```

### Why this is general (not per-builtin)

- The threadlocal mechanism is universal: evaluators save, builtins consume
- Builtins already know which value is problematic (that's inherent to the check)
- Adding `.location = err.getArgSource(idx)` is a one-line change per error site
- No new "knowledge" is added — just plumbing the existing knowledge to the display

---

## Task Sequence

```
BE5   Macro expansion source preservation
  5a  Add source fields to PersistentList/PersistentVector
  5b  formToValue/valueToForm source transfer
  5c  expandMacro top-level source stamp
  5d  Verify: defn, when, cond, -> macros

BE6   Argument-level error source
  6a  Column tracking in VM (Chunk columns array, Compiler save/restore)
  6b  Threadlocal arg source API in error.zig
  6c  TreeWalk arg source saving
  6d  VM arg source saving (binary ops)
  6e  Builtins: arithmetic error sites use getArgSource

BE4   Integration verification
      Complex nesting tests, both backends, macro + nested errors
```

## Expected Results

After BE5+BE6:

```
;; Macro expansion — source preserved
(defn add [x y] (+ x y))
(add 1 "hello")
→ Location: test.clj:1:16   (points to (+ x y) inside defn body)
   ^--- Cannot cast string to number

;; Nested expression — argument-level
(+ 1 (/ 10 0))
→ Location: test.clj:1:13   (points to 0)
               ^--- Divide by zero

;; Type error — problematic argument
(+ 1 "x")
→ Location: test.clj:1:5    (points to "x")
       ^--- Cannot cast string to number
```
