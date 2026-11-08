# Fractal zoom: one Mandelbrot, nineteen engines

A Mandelbrot explorer where the same picture is rendered by kernels written in
Zig, C and Rust (compiled to WebAssembly), by plain Clojure, by
replikativ/raster on the JVM and by CUDA on the GPU. The page zooms, pans and
compares any two engines side by side. Every exact engine paints the same
bytes, and `golden.edn` proves it.

```
browser (re-frame + reagent, web/)
  ├── browser-zig, browser-zig-simd, browser-c, browser-rust   wasm in the tab
  ├── browser-js                                               plain JavaScript
  ├── cljw server (server.clj, port 8080)
  │     zig, c, rust on zwasm jit and interp, zig-simd on jit, cljw-clj
  └── JVM server (jvm/, port 8081)
        raster-jvm, raster-jvm-1t, raster-simd, cuda-f64, cuda-f32, clojure-jvm
```

## Run

```sh
zig build -Dwasm -Doptimize=ReleaseSafe              # the wasm-enabled cljw
zig-out/bin/cljw docs/examples/fractal/server.clj    # page + cljw engines, :8080
(cd docs/examples/fractal/jvm && clojure -M:jvm:serve)  # optional: raster + CUDA, :8081
```

Open http://localhost:8080. The page finds the JVM server by itself
(`?jvm=<url>` overrides). Without it, or without a GPU, those engines are absent
from the list and the server prints why (`unavailable: cuda-f64 - ...`).

The page is ClojureScript. `web/public/js/main.js` is committed, so running
needs no Node. To change it: `cd web && npm install && npx shadow-cljs watch app`
with server.clj running, or `npx shadow-cljs release app` for the committed build.

## The page

| input | action |
|---|---|
| wheel, `+` / `-`, double-click (shift: out), pinch | zoom at the cursor |
| drag, arrows, `WASD` | slide x and y |
| x, y, scale fields + Go | jump to a point |
| left / right, Split | pick engines, compare them side by side |
| iter, res | iteration cap, render resolution |
| Tour | continuous zoom into seahorse valley |
| Bench | every engine on a fixed view list, with parity |

The URL hash holds the view, so a deep link reopens it. The live table shows
ms per frame and Miter/s. For a server engine, ms is the guest render time
(`X-Render-Ms`), so network time is excluded.

## Layout

The three processes share one shape, Collect, Promote, Pipeline, Boundary,
around one port: an open set of renderers behind a protocol, discovered into a
registry. No code dispatches on an engine name.

| layer | cljw (`cljw/`, `server.clj`, `bench.clj`) | JVM (`jvm/src/fractal/`) | page (`web/src/fractal/`) |
|---|---|---|---|
| domain | `tile.clj` | `tile.clj`, `palette.clj`, `golden.clj` | `view.cljs` |
| port | `renderer.clj` | `renderer.clj` | `engines.cljs` `IRenderer` |
| adapters | `engines.clj`: `WasmKernel`, `ClojureRaster` | `renderer/raster.clj`, `raster_simd.clj`, `cuda.clj`, `oracle.clj` | `WasmKernel`, `JsRaster`, `RemoteTiles` |
| collect | `engines/discover` | `engines.clj` (an unavailable renderer is data) | `engines/discover` |
| boundary | `server.clj`, `bench.clj` | `http.clj`, `main.clj`, `bench.clj` | `events.cljs` (re-frame fx), `ui.cljs` |

On the JVM a renderer computes only the escape field (count and |z|^2 per
pixel), and `palette.clj` paints it once, above the port. The wasm kernels
paint inside wasm; golden.edn holds them to the same bytes.

## The kernel ABI

Every `.wasm` kernel has no imports and exports:

| export | signature | meaning |
|---|---|---|
| `memory` | | linear memory holding the framebuffer |
| `fb_ptr` | `() -> i32` | byte address of the RGBA8 framebuffer |
| `fb_cap` | `() -> i32` | capacity in pixels (1048576) |
| `set_view` | `(f64 f64 f64) -> i32` | stores cx, cy, scale; 0, or -1 when one is not finite |
| `render` | `(i32 i32 i32) -> i64` | writes `w*h` pixels for the stored view, returns total iterations |
| `render_simd` | `(i32 i32 i32) -> i64` | same output; vectorised in `kernel_simd.wasm` |

Pixel `(x, y)` is `(cx + (x - w/2) scale, cy + (y - h/2) scale)`. The split
into `set_view` and `render` keeps every export within zwasm's JIT call shapes
(`src/runtime/cljw/wasm/gaps.zig`). Each source file's header holds its exact
build recipe; the e2e gate rebuilds them and requires identical bytes.

| file | language | build |
|---|---|---|
| `kernel.zig` | Zig | `zig build-exe` (scalar and simd128) |
| `kernel.c` | C | `zig cc -target wasm32-freestanding` |
| `kernel.rs` | Rust | `rustc --target wasm32-unknown-unknown` |
| `mandel.clj` | Clojure | none: cljw, bb and the JVM run it as is |

## Tests

| suite | what | run |
|---|---|---|
| golden | every exact engine reproduces `golden.edn` (iterations and framebuffer checksum) | `cljw bench.clj`, `clojure -M:jvm:test`, page `:golden` |
| property | test.check: every JVM renderer equals the oracle bit for bit on generated tiles; palette, tile and HTTP laws | `clojure -M:jvm:test` |
| view laws | test.check on the page's view value: zoom keeps the cursor point, pan reverses, hash round-trips, split panes meet | `cd web && npx shadow-cljs compile test && node target/test.js` |
| mutation | 6 escape-rule and 4 palette mutants must each be rejected by the golden views | `clojure -M:jvm:test` |
| page | hive-cljs scenarios: boot, cross-engine parity, zoom, pan, hash, split, bench, JVM and GPU engines | `code cljs e2e run directory=docs/examples/fractal tags=fractal` |
| gate | `test/e2e/phase16_fractal_kernel.sh`: the `:ci` golden views on 8 cljw engines, recipes byte-identical | `bash test/run_all.sh` |

The mutation suite earned its place at once. No golden pixel sat exactly on
|z|^2 = 4, so a bailout of `< 4` instead of `<= 4` passed every view. The
`tip` view puts pixel (4, 4) on c = -2, whose orbit 0, -2, 2, 2, ... stays on
the circle, and the mutant now dies.

## Numbers

RTX 4070 Laptop GPU, Core Ultra 9 185H (22 threads), JDK 27. Best of 5 frames,
render only (CUDA includes device allocation and the copy back).

**full** (512x512, 256 iter, 9.28e6 iterations):

| engine | ms | Miter/s |
|---|---:|---:|
| cuda-f32 | 2.1 | 4507 (not exact) |
| cuda-f64 | 3.2 | 2908 |
| raster-jvm, all cores | 5.1 | 1816 |
| raster-jvm, 1 thread | 22.4 | 414 |
| clojure-jvm (plain Clojure on the JVM) | 35.7 | 260 |
| rust-jit on zwasm | 250 | 37 |
| zig-jit simd128 on zwasm | 281 | 33 |
| c-jit on zwasm | 309 | 30 |
| zig-jit on zwasm | 324 | 29 |
| raster-simd (Vector API lanes) | 346 | 27 |
| c / rust interp on zwasm | 3200 | 2.9 |
| cljw-clj (plain Clojure on cljw) | 4640 | 2.0 |
| zig interp on zwasm | 5424 | 1.7 |

**deep** (1024x768, 4096 iter, 2.39e9 iterations, scale 2e-9):

| engine | ms | Giter/s |
|---|---:|---:|
| cuda-f64 | 180 | 13.3 |
| raster-jvm, all cores | 540 | 4.4 |
| clojure-jvm | 5669 | 0.42 |
| cuda-f32 | 5.7 | wrong: single precision cannot tell neighbouring pixels apart at this scale |

What the numbers say:

- On the GPU, fp64 (with `--fmad=false`) is exact and 3x faster than every CPU
  core together on the deep view. fp32 is 30x faster again, and wrong there.
- raster's escape loop is a typed `deftm` compiled to primitive bytecode, 1.6x
  faster than the same loop in plain Clojure on one thread, and it scales
  across cores through raster's `parallel-for!`.
- raster vectorises `par/map` bodies onto Vector API lanes but cannot vectorise
  a loop with a per-lane exit. The lanes renderer steps every pixel `limit`
  times (w*h*limit steps where the escape loop does sum(counts)), so it is
  exact, vectorised and slow: early exit beats lanes for Mandelbrot on a CPU.
  A GPU has both, thousands of lanes with per-thread exit.
- On cljw, zwasm's JIT runs the wasm kernels 10x to 17x faster than its
  interpreter, and plain Clojure on cljw sits near the interpreter.

## Upstream fixes found by this demo

- replikativ/raster#1574: on a JDK 27 without `--enable-preview`,
  `valhalla-available?` was true, value classes failed to load, and the error
  surfaced as `ClassNotFoundException: raster.types.promote.TLong`. The fix
  probes by defining a value class. Until it is released, `jvm/deps.edn`
  passes `--enable-preview`.
- uncomplicate/clojure-cpp#3: a `keywrod-pointer*` typo made the namespace
  unloadable on current Clojure, and with it clojurecuda. Until it is released,
  `cuda-*` needs a `jvm/local.deps.edn` that points at a patched clojure-cpp,
  otherwise the JVM server lists them as unavailable.
- CUDA 13.5 NVRTC emits PTX a 13.4 driver rejects. `cuda.clj` compiles to a
  CUBIN for the device's own `sm_XY` instead, which minor-version
  compatibility allows.
