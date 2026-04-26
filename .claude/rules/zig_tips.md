---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# Zig 0.16.0 idioms (project rules)

Auto-loaded when editing Zig source. The biggest break from 0.15 is
`std.io` → `std.Io`: `std.io.AnyWriter` is gone (use `*std.Io.Writer`),
`std.io.fixedBufferStream` is gone (use `std.Io.Writer.fixed(&buf)` and
`w.buffered()`), and `std.fs.File.stdout()` moved to `std.Io.File.stdout()`.

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
"unable to resolve inferred error set" with recursion.

```zig
const Writer = std.Io.Writer;

pub fn format(self: Form, w: *Writer) Writer.Error!void { ... }

// Tests (replaces std.io.fixedBufferStream)
var buf: [256]u8 = undefined;
var w: Writer = .fixed(&buf);
try form.format(&w);
try std.testing.expectEqualStrings("expected", w.buffered());
```

For an allocating writer (replaces `ArrayList(u8).writer().any()`):

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

Phase 1–2 is single-threaded; prefer no mutex over a half-wired one. Wire
through `Runtime.io` when concurrency actually arrives (Phase 15).

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

Bit-level layout, e.g. `HeapHeader.flags`:

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
