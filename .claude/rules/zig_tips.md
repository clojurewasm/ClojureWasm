---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# Zig 0.16.0 idioms (project rules)

Auto-loaded when editing Zig source. **AI assistants tend to revert to
pre-0.16 (often pre-0.14) APIs by default — consult this list before
typing any stdlib reference.** When in doubt, grep
`/nix/store/*-zig-0.16.0/lib/std/` for the canonical surface.

## 0.14 → 0.16 removals & renames (must-know)

These are the patterns that compile-fail (or fail silently via deprecated
shim) but AI training corpora overwhelmingly use the old names. Memorise.

| Removed / renamed (0.14 / 0.15)                                         | Use in 0.16.0                                                                                                                  | Notes                                                                                   |
|-------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| `std.io` (lowercase namespace)                                          | `std.Io` (capital I)                                                                                                           | `std.io` namespace effectively gone; `std.Io` is the only canonical module              |
| `std.io.AnyWriter` / `AnyReader`                                        | `*std.Io.Writer` / `*std.Io.Reader`                                                                                            | Type-erased pointer to concrete vtable type                                             |
| `std.io.fixedBufferStream(&buf)`                                        | `var w: std.Io.Writer = .fixed(&buf);`                                                                                         | Reader: `var r: std.Io.Reader = .fixed(&buf);`                                          |
| `std.io.getStdOut/Err/In`                                               | `std.Io.File.stdout/stderr/stdin()`                                                                                            | Returns `File`, then `.writer(io, &buf).interface`                                      |
| `std.io.bufferedWriter` / `BufferedWriter`                              | `file.writer(io, &buf)`                                                                                                        | Buffer is the user-supplied byte slice                                                  |
| `std.io.tty.*`                                                          | `std.Io.Terminal`                                                                                                              | TTY detection / colour                                                                  |
| `list.writer().any()` (allocating)                                      | `var aw: std.Io.Writer.Allocating = .init(alloc);` then `&aw.writer`                                                           | `aw.toOwnedSlice()` extracts                                                            |
| `std.fs.File` (and `.OpenError` / `.Writer` / etc.)                     | `std.Io.File`                                                                                                                  | All file ops now take `io: std.Io`                                                      |
| `std.fs.cwd()`                                                          | `std.Io.Dir.cwd()`                                                                                                             | —                                                                                      |
| `std.fs.openFileAbsolute(path, ...)`                                    | `std.Io.Dir.cwd().openFile(io, path, ...)`                                                                                     | `io` arg now mandatory                                                                  |
| `std.fs.Dir`                                                            | `std.Io.Dir`                                                                                                                   | All dir ops take `io: std.Io`                                                           |
| `std.fs.path.*`                                                         | `std.Io.Dir.path.*`                                                                                                            | `std.fs.path` left as deprecated re-export                                              |
| `std.fs.max_path_bytes` / `max_name_bytes`                              | `std.Io.Dir.max_path_bytes` / `.max_name_bytes`                                                                                | —                                                                                      |
| `std.Thread.Mutex` / `RwLock` / `Condition` / `Semaphore` / `WaitGroup` | `std.Io.Mutex` / `Io.RwLock` / `Io.Semaphore` (with `io: Io` arg), or `std.atomic.Mutex` (lock-free `tryLock` / `unlock` only) | **All `std.Thread.*` sync primitives are gone**                                         |
| `std.heap.GeneralPurposeAllocator(.{})`                                 | `std.heap.DebugAllocator(.{})`                                                                                                 | Same config struct, renamed                                                             |
| `std.ArrayList(T)` (managed, with internal allocator)                   | `std.ArrayList(T)` — **same name, unmanaged behaviour** (per-call allocator)                                                  | The new `ArrayList` IS the old `ArrayListUnmanaged`. `init` takes no allocator          |
| `std.ArrayListUnmanaged(T)`                                             | `std.ArrayList(T)`                                                                                                             | The `Unmanaged` alias is deprecated; the new `ArrayList` is unmanaged                   |
| `std.StringHashMap` / `std.AutoHashMap` (managed)                       | `std.StringHashMap` / `std.AutoHashMap` (unmanaged) or `std.array_hash_map.String` for ordered                                 | Managed wrappers gone; same shape applies as `ArrayList`                                |
| `std.StringArrayHashMapUnmanaged(V)`                                    | `std.array_hash_map.String(V)`                                                                                                 | New name for the ordered string-keyed map                                               |
| `std.mem.copy(T, dest, src)`                                            | `@memcpy(dest, src)` (or `@memmove` if overlapping; or `std.mem.copyForwards` / `copyBackwards` for explicit direction)        | `mem.copy` removed                                                                      |
| `std.mem.indexOf`                                                       | `std.mem.find`                                                                                                                 | —                                                                                      |
| `std.mem.lastIndexOf`                                                   | `std.mem.findLast`                                                                                                             | —                                                                                      |
| `std.mem.lastIndexOfLinear`                                             | `std.mem.findLastLinear`                                                                                                       | linear-scan variant; distinct function from `findLast`                                  |
| `std.mem.indexOfScalar`                                                 | `std.mem.findScalar`                                                                                                           | —                                                                                      |
| `std.mem.lastIndexOfScalar`                                             | `std.mem.findScalarLast`                                                                                                       | —                                                                                      |
| `std.mem.indexOfScalarPos`                                              | `std.mem.findScalarPos`                                                                                                        | —                                                                                      |
| `std.mem.indexOfAny` / `lastIndexOfAny` / `indexOfAnyPos`               | `findAny` / `findLastAny` / `findAnyPos`                                                                                       | —                                                                                      |
| `std.mem.indexOfNone` / `lastIndexOfNone`                               | `findNone` / `findLastNone`                                                                                                    | —                                                                                      |
| `std.mem.indexOfDiff`                                                   | `std.mem.findDiff`                                                                                                             | —                                                                                      |
| `std.mem.indexOfSentinel`                                               | `std.mem.findSentinel`                                                                                                         | —                                                                                      |
| `std.mem.indexOfPos`                                                    | `std.mem.findPos`                                                                                                              | —                                                                                      |
| `std.mem.containsAtLeastScalar(...)`                                    | `std.mem.containsAtLeastScalar2(...)`                                                                                          | Signature changed                                                                       |
| `std.meta.Int(.signed, n)` / `std.meta.Int(.unsigned, n)`               | `@Int(.signed, n)` / `@Int(.unsigned, n)`                                                                                      | Now a builtin in 0.16; `std.meta.Int` is a deprecated wrapper                           |
| `std.mem.readPackedIntNative` / `*Foreign` (read+write)                 | `readPackedInt(T, bytes, bit_offset, .native)` (or `.foreign`)                                                                 | Unified API                                                                             |
| `std.mem.Alignment` as `u29` int                                        | `enum (Alignment)` — use `.fromByteUnits(n)` / `@enumFromInt`                                                                 | No more `@as(u29, ...)` for alignment                                                   |
| `c_void`                                                                | `anyopaque`                                                                                                                    | C ABI                                                                                   |
| `usingnamespace`                                                        | (removed — no replacement; redesign with explicit re-exports)                                                                 | Compile error in 0.16                                                                   |
| `@intToFloat(T, x)` / `@floatToInt(T, x)`                               | `@floatFromInt(x)` / `@intFromFloat(x)`                                                                                        | Result-location inferred                                                                |
| `@boolToInt(x)`                                                         | `@intFromBool(x)`                                                                                                              | —                                                                                      |
| `@enumToInt(x)` / `@intToEnum(T, x)`                                    | `@intFromEnum(x)` / `@enumFromInt(x)`                                                                                          | —                                                                                      |
| `@errToInt` / `@intToErr`                                               | `@intFromError` / `@errorFromInt`                                                                                              | —                                                                                      |
| `@ptrToInt` / `@intToPtr`                                               | `@intFromPtr` / `@ptrFromInt`                                                                                                  | —                                                                                      |
| `@branch`                                                               | `@branchHint(.likely)` (or `.unlikely` / `.cold`); placed **inside** the branch body                                           | —                                                                                      |
| Old `format(self, comptime fmt, options, writer: anytype)`              | `pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void`                                                     | `{}` → `{f}` at call sites                                                             |
| `std.process.argsAlloc(alloc)` (manual main)                            | `pub fn main(init: std.process.Init)` then `init.minimal.args.iterateAllocator(gpa)`                                           | "Juicy Main": `init` bundles `io / arena / gpa / minimal.args / environ_map / preopens` |

## std.mem aliases that still work (informational)

These remain canonical in 0.16, **don't migrate them**:

- `std.mem.eql` / `startsWith` / `endsWith` / `trim` / `trimStart` / `trimEnd`
- `std.mem.splitScalar` / `splitAny` / `splitSequence` (NOT renamed)
- `std.mem.tokenizeScalar` / `tokenizeAny` / `tokenizeSequence` (NOT renamed)
- `std.mem.readInt(T, bytes, .little)` (or `.big`) / `writeInt`
- `@memcpy` / `@memset` / `@memmove` (builtins; replace `mem.copy`)

## Empty `catch`: `catch {}` is the only form Zig 0.16 accepts

Surprising but real. The Zig 0.16 compiler **rejects** the two
"more explicit" forms that AI training data favours:

```zig
something() catch |_| {};                // ERROR: discard of error capture; omit it instead
something() catch |err| { _ = err; };    // ERROR: error set is discarded
something() catch {};                    // OK
```

If a `catch {}` is genuinely the right pattern (best-effort I/O
where there is no recovery and nothing to log to), leave the bare
`catch {}` and add a comment above it explaining *why* swallowing
is fine.

## Optionals: `x.?`, not `x orelse unreachable`

The `.?` shorthand is the canonical "definitely-present optional"
in Zig 0.16. It triggers identical safety checks in safe build
modes, costs the same in release modes, and is shorter.

```zig
const arg0 = arg_it.next().?;                     // OK (canonical)
const arg0 = arg_it.next() orelse unreachable;    // gate-rejected (no_orelse_unreachable)
```

The lint chain enforces this (ADR-0003 / Phase B).

## Exhaustive enum `switch`: prefer enumeration for narrow / fixed enums

For small fixed enums (e.g. `Token.Kind` ~13 tags), enumerate every
tag instead of `else => ...`. When a new tag is added later, the
compiler raises a missing-case error at every switch — useful
regression prevention.

```zig
return switch (token_kind) {
    .lparen, .lbracket, .lbrace => .open,
    .rparen, .rbracket, .rbrace => .close,
    .integer, .float, .string, .symbol, .keyword => .literal,
    .quote, .discard, .symbolic => .reader_macro,
    .eof, .invalid => .terminal,
};
```

For wide *value-dispatch* enums (`Value.Tag`, currently 36+ tags
and growing through Phases 4–15), the inverse rule applies: prefer
`else =>` to express "every other kind I do not accept as operand".
The arithmetic / collection / print primitives all use this idiom;
forcing 36-arm enumeration would balloon code volume without
preventing real bugs (a new tag is *meant* to fall into the error
path until its primitives are wired in).

The lint gate (ADR-0003) does **not** enforce
`require_exhaustive_enum_switch` for this reason. Use judgement.

## Empty function / `if` body: comment inside

Empty bodies are gate-rejected unless they carry a comment
explaining the intent.

```zig
fn nopOp(_: *Runtime, _: *const Node) anyerror!void {
    // Phase-3 placeholder — body lands in Phase 4 with the VM.
}
```

The friction is the point: forces a sentence about intent at the
only moment the author is writing the code.

## tagged union: `switch`, not `==`

```zig
return switch (self) { .nil => true, else => false };  // OK
return self == .nil;                                    // unreliable
```

Initialise with type annotation: `const nil: Value = .nil;`
(not `Value.nil`).

## ArrayList / HashMap: `.empty` + per-call allocator

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
const v = list.pop();   // returns ?T, not T
```

Same pattern for `HashMap`: `.empty`, `put(alloc, k, v)`, `deinit(alloc)`.

The bare `std.ArrayList(T)` in 0.16 IS the old `ArrayListUnmanaged`.
The `Unmanaged` alias is itself deprecated — drop the suffix.

## stdout via `std.Io.File`

```zig
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
const stdout = &stdout_writer.interface;
try stdout.print("hello {s}\n", .{"world"});
try stdout.flush();    // do not forget
```

`writer(io, buf)` requires `io` (a `std.Io` value) — get it from
`std.process.Init` (Juicy Main) or from `Runtime.io`.

## `*std.Io.Writer` for writer params

Type-erased writer; replaces `anytype` for writer parameters and avoids
"unable to resolve inferred error set" with recursion. For tests use
`var w: std.Io.Writer = .fixed(&buf);` then `w.buffered()`.

Allocating writer (replaces `ArrayList(u8).writer().any()`):

```zig
var aw: std.Io.Writer.Allocating = .init(allocator);
errdefer aw.deinit();
try form.format(&aw.writer);
return aw.toOwnedSlice();
```

## Mutex: `std.Thread.Mutex` is gone

Replacements:

- `std.Io.Mutex` — full blocking mutex; `lock`/`unlock` take an `io: Io`
  argument, so the call site must already be threading `Io` through.
- `std.atomic.Mutex` — lock-free `tryLock` / `unlock` only (no blocking
  `lock`).

Phase 1–3 is single-threaded; prefer no mutex over a half-wired one.
Wire through `Runtime.io` when concurrency actually arrives (Phase 15).

## `@branchHint` (not `@branch`)

The hint goes inside the branch body:

```zig
if (cond) {
    @branchHint(.likely);
} else {
    @branchHint(.unlikely);
    return error.Fail;
}
```

## Custom format: `{f}`, not `{}`

Types with a `format` method: `{}` raises "ambiguous format string".

```zig
try w.print("{f}", .{my_value});
```

## What the lint gate (ADR-0003) actually enforces

`zig build lint -- --max-warnings 0` runs four rules:

| Rule                    | What it catches                           |
|-------------------------|-------------------------------------------|
| `no_deprecated`         | any stdlib `/// Deprecated:` reference    |
| `no_orelse_unreachable` | `x orelse unreachable` instead of `x.?`   |
| `no_empty_block`        | empty `{}` body without an inside comment |
| `no_unused`             | unused `const`, function, import          |

`require_exhaustive_enum_switch` was inspected and not adopted —
see ADR-0003 Update for the `Value.Tag` rationale.

The gate is **Mac-host only** — `test/run_all.sh` skips it on
non-Darwin hosts so OrbStack / CI Linux do not need network reach
to fetch zlinter.

## Variable shadowing

Zig disallows locals that shadow struct method names. Rename the local.

```zig
pub fn next(self: *Tokenizer) Token {
    const next_char = self.peek();   // not `next`
}
```

## `comptime StaticStringMap`

Zero-cost lookup at compile time. Use for keyword / opcode tables.

```zig
const keywords = std.StaticStringMap(Keyword).initComptime(.{
    .{ "if",  .if_kw  },
    .{ "def", .def_kw },
});
```

## `ArenaAllocator` for phase-based memory

Bulk-free at phase boundaries. No individual `free` calls.

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const alloc = arena.allocator();
```

## Doc comments

- `//!` — module-level (top of file, before imports). ZLS hover on module.
- `///` — declaration-level (on `pub` types/fns/fields).
- `//`  — inline notes (inside bodies only).

Every file gets `//!`. Every `pub` gets `///` unless the name is
self-evident. No decorative banners (`// ---`).

## `packed struct(<width>)`

Bit-level layout, e.g. NaN-boxing tag bits:

```zig
flags: packed struct(u8) {
    marked: bool,
    frozen: bool,
    _pad: u6,
};
```

## Juicy Main

`pub fn main(init: std.process.Init)` receives `init.io` (`std.Io`),
`init.arena` (process-lifetime arena), `init.gpa` (thread-safe GPA),
`init.minimal.args`, `init.environ_map`, `init.preopens` in one bundle.
Use this signature; do not roll your own arg parsing for stdlib paths.

## `extern struct` for ABI

When laying out structures that cross language / Wasm boundaries, prefer
`extern struct` (C ABI) for top-level layout and `packed struct(<width>)`
for bit-precise sub-fields.
