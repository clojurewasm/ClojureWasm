# Zig 0.15.2 Tips & Pitfalls

Common mistakes and workarounds discovered during development.

## tagged union comparison: use switch, not ==

```zig
// OK
return switch (self) { .nil => true, else => false };
// NG — unreliable for tagged unions
return self == .nil;
```

## ArrayList / HashMap init: use .empty

```zig
var list: std.ArrayList(u8) = .empty;  // not .init(allocator)
defer list.deinit(allocator);
try list.append(allocator, 42);        // allocator passed per call
```

## stdout: buffered writer required

```zig
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
    // recursive calls work fine
    try inner.formatPrStr(w);
}

// In tests: use Writer.fixed + w.buffered()
var buf: [256]u8 = undefined;
var w: Writer = .fixed(&buf);
try form.formatPrStr(&w);
try std.testing.expectEqualStrings("expected", w.buffered());
```

Ref: std lib uses `*Writer` throughout (json, fmt, etc.)
Old `anytype` + `anyerror` pattern is no longer needed.
