# Zig from Clojure: one source, two FFI routes

[`kernel.zig`](./kernel.zig) holds things Zig does well and Clojure does not,
and [`zig_native.clj`](./zig_native.clj) calls each of them twice: as a
sandboxed wasm guest and as a native library through `cljw.ffi`.

```sh
cd docs/examples/zig-native
cljw zig_native.clj        # PASS zig-wasm, SKIP zig-native
zig build-lib -dynamic -O ReleaseFast kernel.zig
cljw zig_native.clj        # PASS zig-wasm, PASS zig-native
```

`test/e2e/phase16_zig_native.sh` runs it in CI against the committed
`kernel.wasm`, then rebuilds both artifacts from the recipe in the source
header and runs it again.

| export | Zig feature | from Clojure |
|---|---|---|
| `nth_prime` | a 10,000-prime table computed by the compiler (`comptime`) | `(nth-prime 9999) ;=> 104729`, a table lookup |
| `opcode` | `std.StaticStringMap`, a keyword table built at compile time | `"pow" ;=> 5`, `"mod" ;=> -1` |
| `dot` | `@Vector(4, f64)` SIMD, four lanes per step | equals `(reduce + (map * xs xs))` |
| `popcount`, `bitrev` | `@popCount`, `@bitReverse` | `(popcount 255) ;=> 8` |
| `blake3` | `std.crypto.hash.Blake3` | `"abc"` hashes to the reference digest |

## Two routes

| | wasm (`wasm/load`) | native (`cljw.ffi`) |
|---|---|---|
| build | `zig build-exe -target wasm32-freestanding` | `zig build-lib -dynamic` |
| artifact | `kernel.wasm`, 47 KB, any OS | `libkernel.so` / `.dylib`, per platform |
| safety | sandboxed: fuel, memory cap, a fault is an exception | none: a bad pointer crashes the process |
| data | the guest owns its buffers (`f64_addr`, `byte_addr`), the host fills them with `wasm/mem-write!` (a `double-array` is one memcpy) | `:string` and `:bytes` arguments are copied in; `:pointer` takes a primitive array's storage (no copy) or an address the host owns |
| signatures | `wasm/exports` reads them back | written by hand: `[:double :double] :double` |
| platforms | everywhere cljw runs | x86_64 and aarch64, Linux and macOS |

Only `export fn` with C-ABI types crosses either route. Slices, error unions,
optionals, generics and structs stay inside Zig: flatten them to pointer plus
length and status codes in a thin export.

## What it costs

v1.15.3, ReleaseSafe, nanoseconds per call, best of 5 runs of 20,000 calls,
on a loaded host (ratios are stable, absolute numbers are not):

| call | ns |
|---|---|
| empty Clojure fn | 167 |
| `cljw.ffi` native call | 342 |
| wasm, `:interp` | 550 |
| wasm, `:jit`, a tiny module | 1,321 |
| wasm, `:jit`, this 47 KB module | 5,600 |

| work | Clojure | Zig through `cljw.ffi` |
|---|---|---|
| dot product, 1,000 doubles | 1.85 ms | 12.2 µs |
| dot product, 100,000 doubles | 357 ms | 1.2 to 5.5 ms, mostly copying the `:bytes` arguments |
| the 1,000th prime | 294 ms by trial division | 1 µs from the compile-time table |

Cross the boundary with big pieces of work, not per element: building a
`:bytes` argument one double at a time in Clojure (`f64s->bytes` here) costs
more than the whole computation.

## Known limits

- wasm `i64` values cross exactly only within ±2^47: larger results come back
  as a lossy `Double` and larger arguments are rejected
  (CLJW-WASM-I64-FULL-RANGE). The native route carries all 64 bits.
- `:jit` call overhead grows with module size (CLJW-WASM-JIT-PERCALL-SCALES).
- Primitive arrays are contiguous native storage (ADR-0204): pass a
  `double-array` as `:pointer` instead of packing `:bytes`. Native buffers
  that outlive one call are CLJW-FFI-NATIVE-BUFFER.
