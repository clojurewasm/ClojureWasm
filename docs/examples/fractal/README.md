# Fractal zoom: one kernel.wasm, server and browser

A Mandelbrot explorer where the same WebAssembly module renders in the
browser and on native cljw, and the page compares the engines live. It uses
the retired cw-playground's split (`docs/works/demos.md` section 4): cljw's own
HTTP server (`cljw.http.server/run-server`) serves the page and renders tiles
with zwasm; the browser also instantiates the identical `kernel.wasm`. No JVM,
no Node, no CDN.

| file | role |
|---|---|
| [`kernel.zig`](./kernel.zig) | the kernel; its header holds the exact build recipes |
| `kernel.wasm` | scalar build, no imports, runs on every engine |
| `kernel_simd.wasm` | simd128 build, for JIT engines only |
| [`server.clj`](./server.clj) | page, kernel and tile server |
| [`index.html`](./index.html) | the viewer, one self-contained file |
| [`bench.clj`](./bench.clj) | native benchmark with strict cross-engine parity |
| [`verify.mjs`](./verify.mjs) | Node oracle for the same parity, byte for byte |

## Run

```sh
zig build -Dwasm -Doptimize=ReleaseSafe
zig-out/bin/cljw docs/examples/fractal/server.clj [port]   # default 8080
```

Open http://localhost:8080. The server loads one instance per engine at
startup and reuses it; each request runs `set_view` then `render` under that
instance's lock.

| route | answer |
|---|---|
| `GET /` | the page |
| `GET /kernel.wasm` | the scalar kernel, `application/wasm` |
| `GET /engines` | the server engines present, e.g. `{"engines":["jit","interp","jit-simd"]}` |
| `GET /tile?cx=&cy=&scale=&w=&h=&iter=&engine=` | `w*h*4` raw RGBA bytes, with `X-Render-Ms` and `X-Iters` headers |

`engine` is `jit` (scalar kernel on zwasm's JIT), `jit-simd` (`kernel_simd.wasm`
on the JIT, when the file is present) or `interp` (scalar kernel on zwasm's
interpreter, which has no SIMD). `KERNEL=/path/to/other.wasm` overrides the
scalar module.

The tile body is a `byte-array` from `wasm/mem-read-array`, served verbatim:
`cljw.http.server` copies a primitive byte-array `:body` as is.

## The page

Mouse wheel zooms around the cursor, drag pans, double-click zooms in, the
slider sets the iteration cap, Reset returns home. Modes: Browser, each server
engine, and Split (browser on the left half, server on the right, same view).
Bench renders a fixed view list on every engine and tabulates the results.

- **ms/frame**: for the browser, wall time of the `render` call. For a server
  engine, the guest render time only (`X-Render-Ms`), so network and copy time
  are excluded and the comparison is engine against engine.
- **Miter/s**: total Mandelbrot iterations (`render`'s return value) divided
  by that time. It moves with zoom depth and the iteration cap, so compare
  engines within one view, not views against each other.

## The kernel ABI

| export | signature | meaning |
|---|---|---|
| `memory` | | linear memory holding the framebuffer |
| `fb_ptr` | `() -> i32` | byte address of the RGBA8 framebuffer |
| `fb_cap` | `() -> i32` | capacity in pixels (1048576) |
| `set_view` | `(f64 f64 f64) -> i32` | stores cx, cy, scale; 0, or -1 when one is not finite |
| `render` | `(i32 i32 i32) -> i64` | writes `w*h` pixels for the stored view, returns total iterations, -1 on invalid input |
| `render_simd` | `(i32 i32 i32) -> i64` | same output; vectorised in `kernel_simd.wasm`, scalarised in `kernel.wasm` |

Pixel `(px, py)` is the point `(cx + (px - w/2) * scale, cy + (py - h/2) * scale)`.

The shape is set by two gaps in cljw's JIT call boundary (`src/runtime/cljw/wasm/gaps.zig`):
an export with more than 5 parameters does not dispatch (`jit_wide_arity`), and
neither does a zero-result export of this shape (`jit_void_window`). Hence a
separate `set_view` that returns `i32`. Both are tracked by
CLJW-WASM-JIT-CALL-SHAPES.

## Bench

```sh
zig-out/bin/cljw docs/examples/fractal/bench.clj
```

It renders a view list on the scalar kernel (`:jit`, `:interp`) and the simd128
kernel (`:jit`), asserts identical iteration totals and framebuffer checksums
across all of them, and writes `out.ppm` (ignored by git).

Measured on an x86_64 Linux host under load, 512x512 full set, iter 256
(ratios are the stable part, absolutes are not):

| engine | ms/frame | Miter/s |
|---|---|---|
| zwasm JIT, scalar | 275 | 33.7 |
| zwasm JIT, simd128 | 589 | 15.8 |
| zwasm interpreter | 3717 | 2.5 |

On this view the simd128 build is slower than scalar on zwasm's JIT, and the
interpreter is about 13x behind the JIT. Compare the browser engine against
these in the page.

## Gate

`test/e2e/phase16_fractal_kernel.sh` runs the parity assertions on the
committed artifacts, rebuilds both from the recipes in `kernel.zig`, and
requires byte equality with the committed files.
