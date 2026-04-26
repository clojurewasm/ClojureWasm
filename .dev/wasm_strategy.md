# Wasm / edge strategy (pre-Phase-19 deep dive)

> Standalone deep dive complementing ROADMAP §8. Frozen at Day 1 so the
> Phase-14 (CLI build) and Phase-19 (Wasm FFI) work have a clear target
> shape, not a late-binding choice.
>
> Final commitment to **Hybrid (Option C)** is the position taken here.
> Promote to an ADR once Phase 14 design starts.

## Three options considered

### Option A — Native runtime that calls Wasm modules

The v1 ClojureWasm shape: `cljw` is a native binary; Clojure code calls
into Wasm via `(wasm/load "lib.wasm")`.

- Pros: minimal change; v1 has shown it works.
- Cons: no Clojure on edge runtimes; the differentiation axis "Wasm-native
  Clojure" is missed.

### Option B — Pure Wasm component

`cljw` itself compiles to a Wasm Component (`wasm32-wasi`). Native binary
goes away or becomes secondary.

- Pros: edge-native by construction. Clean Component Model story.
- Cons: development friction (Wasm-only debugging), some Zig stdlib
  features are not yet stable on `wasm32-wasi` (notably `std.Io.Evented`).

### Option C — Hybrid (selected)

Same source tree produces two artifacts:

1. **Native CLI** (`cljw`): macOS / Linux × x86_64 / aarch64.
2. **Wasm Component** (`cljw.wasm`): WASI 0.2 / Component Model conformant,
   exports `clojure.eval` and friends via WIT.

- Pros: best of both. Native is the ergonomic developer story; Wasm
  Component is the deployment differentiator. Zig 0.16's `std.Io` DI is
  exactly the abstraction needed to keep one source tree happy on both.
- Cons: two CI matrices, two binary sizes to track, WIT layer to design.

## Adopted: Option C (Hybrid)

`build.zig` accepts target options that select the artifact. The `Runtime`
struct does not depend on the backend; the `std.Io` abstraction does the
switch.

```sh
zig build                                     # native cljw
zig build -Dtarget=wasm32-wasi -Dcomponent    # wasm component cljw.wasm
```

(Concrete flag names land in Phase 14 implementation.)

## Pod system (the escape hatch for Tier-C/D libraries)

Babashka's pods are subprocess-based external Clojure libraries. v2's pods
are **Wasm Components** loaded into the same process.

WIT sketch:

```wit
package cljw:pod;

interface clojure-pod {
    use cljw:value/types.{value};
    invoke: func(name: string, args: list<value>) -> result<value, string>;
    describe: func() -> result<string, string>;   // EDN describing exported fns
}
```

Clojure-side:

```clojure
(require '[my-lib :as l :pod "my.wasm"])
(l/foo 1 2)   ;; dispatches to my.wasm's clojure-pod/invoke
```

The pod system exists specifically so that **Tier-C/D libraries get a way
to ship without touching core code** (see `.claude/rules/compat_tiers.md`
and ROADMAP §6.4).

## Phase timeline

| Phase    | Wasm-related deliverable                                        |
|----------|------------------------------------------------------------------|
| 14       | `zig build -Dcomponent` produces a minimal Wasm Component (export `clojure.eval` only). Pod loader interface drafted. |
| 15       | Pod loader implemented (subprocess-style first, then in-process). |
| 18       | `modules/wasm/` (cljw.wasm namespace) for native-side Wasm calling. |
| 19       | zwasm import + WIT auto-binding (`(wasm/component "x.wasm")` produces a Clojure ns). |
| 19+      | WASI 0.3 (concurrency, streaming) integration once stable.       |
| v0.2+    | WasmGC backend evaluation (currently linear memory + NaN boxing). |

## Open questions (resolve before Phase 14 / 19 starts)

1. **WasmGC vs linear memory**: NaN boxing competes with WasmGC's
   nullable refs. Initial line is linear memory + NaN boxing on the Wasm
   side too (consistent with native). Re-measure before v0.2.
2. **WIT representation of Clojure values**: how does WIT's `record` /
   `variant` map to maps / records? RFC due before Phase 19.
3. **Pod identity / security**: pods load arbitrary Wasm — capability
   model? signing? defer to Phase 15 with an ADR.
4. **Component vs core (preview1)**: prefer Component Model (preview2 /
   WASI 0.2). Drop preview1 fallbacks unless a target host requires them.
5. **`std.Io.Evented` on WASI 0.3**: we want async pod calls eventually;
   currently the std.Io WASI backend does not exist. Track upstream.

## Differentiation re-stated (consequences of choosing C)

The hybrid choice is what makes the three differentiation axes (ROADMAP
§1.2) all hold simultaneously:

1. **Edge-native Clojure** (only possible with the Wasm Component artifact)
2. **Wasm-native interop** (loading Wasm modules / pods inside Clojure)
3. **Comprehensible runtime** (one source tree, not two)
