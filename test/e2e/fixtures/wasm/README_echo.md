# `echo.component.wasm` — the typed marshalling fixture (D-404 / D-567)

Every WIT value type whose Canonical ABI the ADR-0135 table maps, in one
component: `bool s32 u64 f32 f64 char string enum option option<option<>>
result variant list record flags tuple` — 16 lifted functions.

## Provenance

Built from **ClojureWit**'s hand-written WAT guest
(`~/Documents/MyProducts/ClojureWit/dev/resources/echo.{wat,wit}`, EPL-2.0, same
org). Deliberately hand-written WAT rather than a Rust guest: it needs no
toolchain beyond `wasm-tools`, which is what makes it usable as a *shared*
falsifier for both repos' mapping tables. Rebuild with:

```sh
W=path/to/ClojureWit/dev/resources
wasm-tools parse "$W/echo.wat" -o echo.core.wasm
wasm-tools component embed "$W/echo.wit" echo.core.wasm -o echo.embed.wasm
wasm-tools component new echo.embed.wasm -o echo.component.wasm
```

Note the checked-in `echo.component.wasm` in ClojureWit is **older than its own
`echo.wat`** (838 bytes, scalars only, built 2026-07-30 01:30 against a WAT last
touched 05:12). Rebuild rather than copy.

## Status: it loads and runs

The gap recorded below is FIXED. Measured 2026-10-08 on cljw v1.14.11: the
16-export component loads with `wasm/load-component`, and `component-call`
round-trips `echo-f64` (1.5 -> 1.5) and `echo-list-u32` ([1 2 3] -> [1 2 3]).
The section below is kept as history, with its root cause.

## History: why it did not run (the >= 2-export InvalidSort gap, fixed)

cljw could not load it, and neither could zwasm's own CLI — so the gap is
engine-side, not cljw-side. **`zwasm` rejects any component with two or more
exports** with `InvalidSort`. Minimal reproduction, `two_export_component.wasm`
in this directory: two scalar `s32`/`bool` echoes, nothing else.

Root cause located in `zwasm/src/feature/component/types.zig`: the
`component_funcs` index space is appended for imports, canon lifts and aliases,
but **not for the entries that component-level `export`s themselves create**. So
from the second export onward every lift's index reads out of bounds and
`validate.zig`'s `.func => if (ex.index >= info.component_funcs.items.len)`
fires. Tracked as cljw **D-567** and zwasm **D-527**.

This is why it went unnoticed: cljw's only component fixtures were
`greet_component.wasm` and `resource_counter.wasm`, both single-export.
