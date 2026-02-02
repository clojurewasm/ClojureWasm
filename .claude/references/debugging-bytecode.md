# Debugging Bytecode

`Chunk.dump(writer)` and `FnProto.dump(writer)` in `src/common/bytecode/chunk.zig`
produce human-readable bytecode disassembly. Use within tests:

```zig
// In any test — dump to stderr for quick visual inspection
var buf: [4096]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try chunk.dump(&w);
std.debug.print("\n{s}\n", .{w.buffered()});
```

When a compiler or VM test fails unexpectedly, add a dump call before the
failing assertion to see what was actually compiled. Remove after debugging.
