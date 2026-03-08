---
paths:
  - "src/**/*.zig"
  - "ext/**/*.zig"
  - "build.zig"
---

# Zig 0.15.2 Tips & Pitfalls

Common mistakes and workarounds discovered during CW/zwasm development.

## tagged union comparison: use switch, not ==

```zig
// OK
return switch (self) { .nil => true, else => false };
// NG — unreliable for tagged unions
return self == .nil;
```

Also, initialize with type annotation, not enum tag:

```zig
// OK
const nil: Value = .nil;
// NG — may be interpreted as enum tag
const nil = Value.nil;
```

## ArrayList / HashMap init: use .empty

```zig
var list: std.ArrayList(u8) = .empty;  // not .init(allocator)
defer list.deinit(allocator);
try list.append(allocator, 42);        // allocator passed per call
```

## stdout: buffered writer required

```zig
// NG — does not exist in 0.15.2
const stdout = std.io.getStdOut().writer();

// OK — buffer + flush required
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
const stdout = &writer.interface;
// ... write ...
try stdout.flush();  // don't forget
```

## Use std.Io.Writer (type-erased) instead of anytype for writers

In 0.15.2, `std.Io.Writer` is the new type-erased writer.
`GenericWriter` and `fixedBufferStream` are deprecated.

Prefer `*std.Io.Writer` over `anytype` for writer parameters.
This avoids the "unable to resolve inferred error set" problem
with recursive functions, and the error type is a concrete
`error{WriteFailed}` instead of `anyerror`.

```zig
const Writer = std.Io.Writer;

// OK — concrete type, works with recursion, precise error set
pub fn formatPrStr(self: Form, w: *Writer) Writer.Error!void {
    try inner.formatPrStr(w);
}

// In tests: use Writer.fixed + w.buffered()
var buf: [256]u8 = undefined;
var w: Writer = .fixed(&buf);
try form.formatPrStr(&w);
try std.testing.expectEqualStrings("expected", w.buffered());
```

## @branchHint, not @branch

```zig
// OK — hint goes INSIDE the branch body
if (likely_condition) {
    @branchHint(.likely);
    // hot path
} else {
    @branchHint(.unlikely);
    return error.Fail;
}

// NG — @branch(.likely, cond) does not exist
```

Use `.likely` for normal path, `.unlikely` / `.cold` for error path.
Most effective in loops, opcode dispatch, and parser branches.

## Custom format method: use {f}, not {}

Types with a `format` method cause "ambiguous format string"
compile error when printed with `{}`. Use `{f}` or `{any}`,
or call format explicitly.

```zig
// NG — compile error: ambiguous format string
try w.print("{}", .{my_value});

// OK — explicitly calls format method
try w.print("{f}", .{my_value});

// OK — call format directly (most reliable)
try w.writeAll("value: ");
try my_value.format("", .{}, w);
```

## Variable name shadowing with method names

Zig disallows local variables that shadow struct method names.

```zig
pub fn next(self: *Tokenizer) Token {
    // NG — shadows method name "next"
    // const next = self.peek();

    // OK — use a different name
    const next_char = self.peek();
}
```

## comptime StaticStringMap for keyword/opcode tables

Zero-cost lookup tables built at compile time.

```zig
const keywords = std.StaticStringMap(Keyword).initComptime(.{
    .{ "if", .if_kw },
    .{ "def", .def_kw },
    .{ "fn", .fn_kw },
});

pub fn lookupKeyword(str: []const u8) ?Keyword {
    return keywords.get(str);
}
```

Zero runtime cost, zero heap allocation. Use for keyword tables,
opcode metadata, special form dispatch.

## ArenaAllocator for phase-based memory

Language processors generate many small allocations (AST nodes, tokens)
that can be bulk-freed at phase boundaries.

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();  // bulk free everything
const allocator = arena.allocator();

const node = try allocator.create(AstNode);  // no individual free needed
```

Benefits: no free calls, no fragmentation, cache-friendly.
Pattern: separate arenas per phase (lex, parse, compile), deinit at phase end.
