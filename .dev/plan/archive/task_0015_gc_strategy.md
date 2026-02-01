# Task 2.4: Create GcStrategy trait + initial NativeGc stub

## References
- future.md SS5: GC modular design, 3-layer architecture
- Beta: src/gc/gc_allocator.zig (GcAllocator), src/gc/gc.zig (GC)
- Roadmap notes: "SS5: GcStrategy vtable. Start with arena allocator, real GC deferred. Just alloc + no-op collect initially"

## Plan

### Goal
Define a `GcStrategy` vtable-based trait in `src/common/gc.zig` and an initial
`ArenaGc` implementation that wraps `std.heap.ArenaAllocator`. Real GC (mark-sweep,
semispace) is deferred — this task only provides the abstraction layer.

### Design Decisions

1. **File location**: `src/common/gc.zig` — shared between native/wasm paths
2. **Vtable pattern**: Zig fat-pointer idiom (`ptr: *anyopaque` + vtable struct)
   matching the pattern used in `std.mem.Allocator`
3. **Initial implementation**: `ArenaGc` — wraps ArenaAllocator, no-op collect.
   This gives us a working allocator to use in Env/VM without real GC overhead.
4. **RootSet**: Placeholder type (empty struct for now). Will be filled in when
   VM stack walking is implemented (Task 2.7+).
5. **Stats**: Basic allocation stats (bytes_allocated, alloc_count) for debugging.

### Interface

```zig
pub const GcStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        alloc: *const fn (ptr: *anyopaque, size: usize, align: u8) ?[*]u8,
        collect: *const fn (ptr: *anyopaque, roots: RootSet) void,
        shouldCollect: *const fn (ptr: *anyopaque) bool,
        stats: *const fn (ptr: *anyopaque) Stats,
    };

    // convenience methods delegating to vtable
    pub fn alloc(...) ...
    pub fn collect(...) ...
    pub fn shouldCollect(...) ...
    pub fn stats(...) ...
};
```

### ArenaGc (initial stub)

- Wraps `std.heap.ArenaAllocator`
- `alloc`: delegates to arena allocator
- `collect`: no-op (arena frees all at once on deinit)
- `shouldCollect`: always returns false
- `stats`: tracks bytes_allocated and alloc_count
- `strategy()`: returns `GcStrategy` fat pointer
- `allocator()`: returns `std.mem.Allocator` for Zig stdlib compatibility

### Test Cases (TDD order)

1. ArenaGc.init creates valid instance
2. ArenaGc.strategy().alloc returns non-null pointer
3. ArenaGc.strategy().shouldCollect returns false
4. ArenaGc.strategy().collect is no-op (doesn't crash)
5. ArenaGc.strategy().stats tracks allocation count
6. ArenaGc.allocator() returns usable std.mem.Allocator
7. Multiple allocations tracked correctly in stats

### Not in scope
- Real GC (mark-sweep, semispace) — future tasks
- WasmRtGc — future tasks (wasm_rt backend)
- YieldPoint / safe points — Task 2.7 (VM)
- Integration with Env — can be done separately after this task

## Log

- Created src/common/gc.zig with GcStrategy vtable trait and ArenaGc stub
- GcStrategy uses Zig fat-pointer idiom (ptr + vtable), matching std.mem.Allocator pattern
- ArenaGc wraps std.heap.ArenaAllocator with no-op collect and stats tracking
- Used std.mem.Alignment enum for alloc alignment parameter (Zig 0.15.2 API)
- Added gc module to root.zig
- All 7 tests passing: init, alloc, shouldCollect, collect no-op, stats tracking, std allocator, multiple allocs
- DONE
