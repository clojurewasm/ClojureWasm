# Fractal zoom: one kernel.wasm, three engines

A Mandelbrot explorer where the **same** WebAssembly module renders on three
engines at once, and the page compares them live:

- **Browser**: the tab instantiates `/kernel.wasm` itself (V8 or
  SpiderMonkey JIT, plus SIMD when the module ships `render_simd`).
- **Server-jit**: native cljw renders the tile with zwasm's JIT and returns
  raw RGBA bytes.
- **Server-interp**: the same, on zwasm's tree-walking interpreter.

The split is the retired cw-playground's shape (docs/works/demos.md section
4): cljw's own HTTP server (`cljw.http.server/run-server`) serves the page and
the compute; no JVM, no node, no CDN.

## Run

```sh
zig build -Dwasm -Doptimize=ReleaseSafe     # the wasm-enabled cljw binary
cljw docs/examples/fractal/server.clj [port]   # default 8080
```

Open http://localhost:8080. The server loads one zwasm instance per engine at
startup and reuses it across requests.

`KERNEL=/path/to/other.wasm cljw docs/examples/fractal/server.clj` overrides
the module. When the kernel ships SIMD as a sibling file instead of an export,
drop `kernel_simd.wasm` next to it; the JIT leg picks it up. The interpreter
cannot run SIMD (v128), so `server-interp` always uses the scalar `render`.

## The kernel ABI

`kernel.wasm` has no imports and exports:

| export | signature | meaning |
|---|---|---|
| `memory` | | linear memory holding the framebuffer |
| `fb_ptr` | `() -> i32` | byte address of the RGBA8 framebuffer |
| `fb_cap` | `() -> i32` | framebuffer capacity in pixels (1048576) |
| `set_view` | `(f64 f64 f64) -> i32` | stores cx, cy, scale; 0, or -1 when a coordinate is not finite |
| `render` | `(i32 i32 i32) -> i64` | writes `w*h` RGBA pixels at `fb_ptr` for the stored view, returns total iterations |
| `render_simd` | `(i32 i32 i32) -> i64` | SIMD twin, ships only in `kernel_simd.wasm` |

Pixel `(px, py)` is the complex point `(cx + (px - w/2) * scale, cy + (py - h/2) * scale)`.

The two-call shape (view, then render) keeps every export at or below the
5-parameter dispatch limit of zwasm's JIT: a single 6-parameter `render`
traps at invoke (measured, gaps.zig `jit_wide_arity`).

## Run

```sh
zig build -Dwasm -Doptimize=ReleaseSafe     # the wasm-enabled cljw binary
cljw docs/examples/fractal/server.clj [port]   # default 8080
```

## The page

Mouse wheel zooms around the cursor, drag pans, double-click zooms in, the
slider sets the iteration cap, Reset returns home. Modes: Browser,
Server-jit, Server-interp, and Split (browser on the left half, server-jit on
the right, same view). All of it is one self-contained file, works at phone
width, dark by default.

## The numbers

- **ms/frame**: for the browser leg, wall time of the `render` call. For the
  server legs, the guest render time only (the `X-Render-Ms` response header);
  network and byte-copy time are excluded so the comparison is engine against
  engine.
- **Miter/s**: total Mandelbrot iterations (the `i64` `render` returns)
  divided by that time. It scales with both zoom depth and the iteration cap,
  so compare engines within one view, not views against each other.
- The rolling chart plots ms/frame per engine over the last 120 frames.
- **Bench** renders a fixed list of views at one size on all three engines and
  tabulates ms and Miter/s, handy on a fresh load before you touch anything.

Measured on the author's x86_64 host (512x512 full set, iter 256; ratios are
the stable part, absolutes are not):

| engine | ms/frame | Miter/s |
|---|---|---|
| zwasm JIT, scalar | 275 | 33.7 |
| zwasm JIT, simd128 | 589 | 15.8 |
| zwasm interpreter | 3717 | 2.5 |

Two honest edges: on zwasm's JIT the SIMD build is SLOWER than scalar (the
per-call v128 dispatch costs more than the vectorisation wins at this tile
size), and the interpreter trails the JIT by roughly 13x, in line with cljw's
own FFI measurement of ~15x on compute-bound bodies. The browser JIT (V8 /
SpiderMonkey) is where SIMD pays off normally; compare it against server-jit
in the page itself.

## Known engine edges

`render` takes 6 parameters. zwasm's JIT is listed as possibly not dispatching
exports with more than 5; if the JIT leg traps with that diagnosis, the remedy
is structural (the kernel packs params) or the JIT leg falls back to interp.
The trap message names the shape and the option.
