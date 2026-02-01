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

## anyerror for recursive functions with anytype writer

Zig cannot resolve inferred error sets (`!void`) for recursive functions
that take `anytype` parameters. Use `anyerror!void` as a workaround.

```zig
// NG — "unable to resolve inferred error set"
pub fn format(self: Form, writer: anytype) !void {
    // ... recursive call to child.format(writer) ...
}

// OK — explicit anyerror
pub fn format(self: Form, writer: anytype) anyerror!void {
    // ... works with recursion ...
}
```

Open Zig issue: https://github.com/ziglang/zig/issues/2971
When resolved upstream, replace `anyerror!` with `!`.
