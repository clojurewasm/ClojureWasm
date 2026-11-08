# `spin_component.wasm`: the component budget fixture (CLJW-COMPONENT-FUEL)

Four scalar exports (see `spin.wit`):

| export | behaviour | what it proves |
|---|---|---|
| `spin` | `loop { br 0 }`, never returns | only a fuel budget brings the caller back |
| `ok` | returns 42 | the control; the component itself works |
| `burn(n)` | counts `n` down, returns `n` | repeated calls exhaust the per-instance fuel budget |
| `grow(pages)` | `memory.grow`, previous size or -1 | `:max-memory-pages` caps linear memory |

Hand-written WAT, like `echo.component.wasm` (README_echo.md): no Rust or C
toolchain, only `wasm-tools`. `spin.wasm` is the same WAT as a plain core
module, so the `wasm/load` + `wasm/call` path is exercised on the same exports.
Rebuild both from this directory:

```sh
wasm-tools parse spin.wat -o spin.wasm
wasm-tools component embed spin.wit spin.wasm -o spin.embed.wasm
wasm-tools component new spin.embed.wasm -o spin_component.wasm
rm spin.embed.wasm
```

The component has no imports, so zwasm opens it on the single-embedded-module
path (`Opened.single`); the WASI-P2 graph path is exercised by the other
fixtures.

## Caller-selected budgets

A cached handle accepts the same fuel and memory axes as `wasm/load`:

```clojure
(def h (wasm/load-component "spin_component.wasm"
                           {:fuel 1000 :max-memory-pages 2}))
(wasm/component-call h "ok") ; 42
```

Fuel is cumulative over the instance lifetime; calls do not refill it. An
exhausted handle keeps failing. Load a fresh instance for a fresh budget.

Omitting the map or an axis keeps zwasm's finite default. As on `wasm/load`,
zero or negative values explicitly remove that axis's cap for trusted guests.
`:engine` and `:timeout-ms` are rejected: components remain interpreter-backed,
and this API does not enforce a wall-clock deadline. Fuel limits instructions;
it does not bound time spent in host calls.

## The diagnostic

A budget kill is reported as a fuel error, not as a trap, on both paths:

```
wasm/call: 'spin' exhausted the module's fuel budget; ...
WebAssembly component exhausted its fuel budget; the handle stays exhausted, ...
```

A genuine guest fault (`docs/examples/wasm/trap.wasm`, divide by zero) still
reads `trapped`, which is what lets an operator tell a guest bug from a budget.

The no-build regression is `test/e2e/phase16_wasm_component_budget.sh`.
Set `CLJW_BIN` to the binary to verify. It places its own outer process
timeout around the fixture, so a broken fuel implementation cannot hang the
test runner. That test timeout is not a component runtime feature.
