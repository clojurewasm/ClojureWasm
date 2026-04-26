# Concurrency design (pre-Phase-15 deep dive)

> Standalone deep dive complementing ROADMAP §7. Frozen at Day 1 so the
> Phase-15 work has a target shape and the intervening phases (1–14) do
> not silently drift away from it.
>
> Promote any decision below to an ADR before it ships in code.

## Position

- **Single-threaded by design through Phase 14.** No actual concurrency
  primitives are exercised before then; threadlocal binding frames are the
  only cross-thread surface that exists, and they are required by Clojure
  semantics, not by parallelism.
- **Phase 15 wires concurrency in one cohesive pass.** No piecemeal
  `std.Thread.Mutex` workarounds are added before then; the v1 lesson was
  that retrofitting concurrency across 15 files is far worse than
  designing it once on a clear day.

## Mapping table — Clojure reference type ↔ Zig 0.16 mechanism

| Clojure prim     | Zig 0.16 mechanism                                | File                       | Phase |
|------------------|---------------------------------------------------|----------------------------|-------|
| `atom`           | `std.atomic` + CAS retry loop                     | `lang/primitive/atom.zig`  | 15    |
| `agent`          | `std.Thread.Pool` + per-agent `Io.Mutex`          | `lang/primitive/atom.zig`  | 15    |
| `future`         | `std.Io.async` + `Io.Mutex` for blocking deref    | `lang/primitive/atom.zig`  | 15    |
| `promise`        | `Io.Mutex` + `Io.Condition`                       | `lang/primitive/atom.zig`  | 15    |
| `delay`          | `Io.Mutex` (single lock, lazy memoize)            | `lang/primitive/lazy.zig`  | 6     |
| `volatile!`      | `@atomicLoad` / `@atomicStore`                    | `lang/primitive/atom.zig`  | 15    |
| `binding` / `*ns*` / `*err*` | `pub threadlocal var current_frame: ?*BindingFrame` | `runtime/env.zig` | 2 |
| `core.async` go  | `std.Io` fibers + channels                        | `lang/primitive/async.zig` | 15 stretch |

`Io.Mutex.lock(io)` and `Io.async(io, ...)` always receive `rt.io` (DI
through the `Runtime` handle, never a global).

## Out of scope: STM (`ref` / `dosync`)

Inherited from v1's call: implementing `LockingTransaction` correctly is
expensive, and `atom` + `agent` cover ~95 % of real concurrent code.
Calling these returns:

```clojure
(throw (UnsupportedException "STM (ref/dosync) is not supported. Use atom or agent."))
```

## `std.Io` backend selection

Backend is selected at build time:

```sh
zig build -Dio-backend=threaded   # default
zig build -Dio-backend=uring      # Linux production
zig build -Dio-backend=kqueue     # darwin production
zig build -Dio-backend=wasi       # Wasm component build
```

| Backend            | Notes                                                          | Status                   |
|--------------------|----------------------------------------------------------------|--------------------------|
| `std.Io.Threaded`  | Most stable; default for development and tests.                | Production-ready         |
| `std.Io.Uring`     | Linux io_uring backend; high throughput.                       | Experimental in 0.16.x   |
| `std.Io.Kqueue`    | darwin kqueue / GCD backend.                                   | Experimental in 0.16.x   |
| WASI backend       | Wasm component runtime backend.                                | Pending WASI 0.3 stable  |

Re-evaluate Evented backends at the end of Phase 15 (gated decision in
ROADMAP §14.2).

## Threadlocal: when to use, when to avoid

**Use threadlocal** for:

- Clojure dynamic vars (`*ns*`, `*err*`, `*print-length*`, …) implemented
  by `binding`. Required by Clojure semantics.
- Error stack frames carried for stack-trace reporting (`runtime/error.zig`).
- Macro-expansion-only context (`current_env`, `last_thrown_exception`).

**Avoid threadlocal** for:

- Anything that has a clean "owned by struct X" home — put it on the struct.
- Anything an embedder might want to multi-instance.

## `Allocator.VTable` cannot take `io`

The standard `std.mem.Allocator.VTable` callbacks have fixed signatures
(`fn(ctx, len, alignment, ret_addr) ?[*]u8`, etc.). They cannot take an
`io: Io` parameter. Therefore:

- The mark-sweep GC's allocator vtable does **not** lock anywhere.
- Concurrent allocation safety is achieved by either (a) per-thread arena
  or (b) lock-free bump allocator beneath the allocator interface.
- Explicit GC operations (`gc.collect(rt)`, `gc.sweep(rt)`) take `rt` and
  lock internally via `std.Io.Mutex.lock(rt.io)`.

This is recorded as the Phase-5 (mark-sweep) sync strategy. Final choice
between (a) and (b) is deferred to Phase 5 after measurement.

## Open questions (resolve before Phase 15 starts)

1. Per-thread arena vs lock-free bump allocator for the GC backing
   (deferred to Phase 5 with a measurement).
2. Whether `core.async` go blocks ride on `std.Io.async` fibers or on a
   second-class implementation. Stretch goal in Phase 15; ADR required if
   we attempt it.
3. How `(future ...)` deref behaves on a Wasm component build where the
   host thread model differs (likely WASI 0.3 polling-based model).
4. Whether `agent`s share one global `std.Thread.Pool` or get one pool
   per process (probably one global; revisit at Phase 15).
