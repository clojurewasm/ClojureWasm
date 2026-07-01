# Third-party components

ClojureWasm is licensed under EPL-2.0 (see [`LICENSE`](LICENSE)). Unlike a
license-uniform tree, ClojureWasm is an EPL-2.0 project that **builds against**
a small number of external dependencies under other OSI licenses (Apache-2.0,
MIT). None are vendored into this repository — they are fetched by the Zig
package manager at build time (pinned in [`build.zig.zon`](build.zig.zon)) — so
their license terms apply to the fetched artifacts, not to this source tree.

This file is the running inventory; [`NOTICE`](NOTICE) records the Clojure
language lineage separately.

## Build / runtime dependencies (fetched, pinned in build.zig.zon)

- **zwasm** — the embedded WebAssembly engine that powers the Wasm FFI.
  Apache-2.0. Pinned to commit `fc7ff0b3b6404e077b3c186605cf49a15e96cc0a`
  (`v2.0.0-alpha.3`). Resolved only for the Wasm-enabled build (`-Dwasm`); the
  default build does not fetch it.
  Source: <https://github.com/clojurewasm/zwasm>.
- **zlinter** — a development-time Zig linter used by `zig build lint`. MIT.
  Pinned to commit `9b4d67b9725e7137ac876cc628fe5dd2ca5a2681`
  (`ref=0.16.x`). Not part of the runtime; it participates in the gate only.
  Source: <https://github.com/kurtwagner/zlinter>.
  _Known pre-1.0 limitation_: `zlinter` exposes its builder through a top-level
  `@import("zlinter")` in `build.zig`, which the Zig build graph resolves
  **eagerly** — so even a plain `zig build` that never runs `lint` fetches it
  once. Making it lazy needs the dependency to expose a `b.lazyDependency`-able
  builder (upstream); until then this is an accepted development-time fetch, not
  a runtime dependency.

## Clojure language lineage (EPL, see NOTICE)

The namespaces under `src/lang/clj/clojure/**` implement Clojure /
Clojure-contrib APIs (originally © Rich Hickey and contributors, Eclipse Public
License 1.0). Almost all are **independent reimplementations** (no upstream
source text reproduced). Two files reproduce upstream source text and retain the
original notice under EPL-2.0 per EPL-1.0 §7:

- `src/lang/clj/clojure/template.clj` (clojure.template, by Stuart Sierra)
- `src/lang/clj/clojure/core/protocols.clj` (docstrings)

See [`NOTICE`](NOTICE) for the full statement. ClojureWasm is not affiliated
with or endorsed by the Clojure project.

## Maintenance rule

When you add or bump a fetched dependency in `build.zig.zon`, update the
matching row here (exact license + pinned commit/version), so the attribution
never drifts from the pin.
