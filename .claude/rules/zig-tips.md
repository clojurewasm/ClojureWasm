---
paths:
  - "src/**/*.zig"
  - "ext/**/*.zig"
  - "build.zig"
---

# Zig 0.15.2 Tips & Pitfalls

## tagged union: use switch, not ==

```zig
// OK
return switch (self) { .nil => true, else => false };
// NG — unreliable
return self == .nil;
```

Initialize with type annotation: `const nil: Value = .nil;` (not `Value.nil`).

## ArrayList / HashMap: .empty + per-call allocator

```zig
var list: std.ArrayList(u8) = .empty;  // not .init(allocator)
defer list.deinit(allocator);          // allocator required
try list.append(allocator, 42);        // allocator required per call
const val = list.pop();                // returns ?T, not T
```

Same pattern for HashMap: `.empty`, `put(alloc, k, v)`, `deinit(alloc)`.

## stdout: no getStdOut() in 0.15.2

```zig
// NG
const stdout = std.io.getStdOut().writer();

// OK (simple) — direct write
const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
_ = try stdout.write("hello\n");

// OK (buffered) — for formatted output
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
const w = &writer.interface;
try w.flush();  // don't forget
```

## std.Io.Writer: type-erased writer

Use `*std.Io.Writer` instead of `anytype` for writer params.
Avoids "unable to resolve inferred error set" with recursion.

```zig
const Writer = std.Io.Writer;

pub fn format(self: Form, w: *Writer) Writer.Error!void { ... }

// In tests:
var buf: [256]u8 = undefined;
var w: Writer = .fixed(&buf);
try form.format(&w);
try std.testing.expectEqualStrings("expected", w.buffered());
```

## @branchHint (not @branch)

Hint goes INSIDE the branch body:

```zig
if (cond) {
    @branchHint(.likely);
} else {
    @branchHint(.unlikely);
    return error.Fail;
}
```

## Custom format: use {f}, not {}

Types with `format` method → `{}` causes "ambiguous format string".

```zig
try w.print("{f}", .{my_value});   // OK
try w.print("{}", .{my_value});    // NG — compile error
```

## Variable name shadowing

Zig disallows locals that shadow struct method names.

```zig
pub fn next(self: *Tokenizer) Token {
    const next_char = self.peek();  // OK — "next" would shadow
}
```

## comptime StaticStringMap

Zero-cost compile-time lookup. Use for keyword/opcode tables.

```zig
const keywords = std.StaticStringMap(Keyword).initComptime(.{
    .{ "if", .if_kw },
    .{ "def", .def_kw },
});
```

## ArenaAllocator for phase-based memory

Bulk-free at phase boundaries. No individual free calls needed.

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const alloc = arena.allocator();
```
