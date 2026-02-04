---
paths:
  - src/clj/**/*.clj
  - src/common/analyzer/**
  - src/common/builtin/**
---

# Java Interop Policy

**Do NOT skip features** that look JVM-specific. Check this table first,
then investigate Zig equivalents. Avoid workarounds and stubs — implement
the real feature or document why it's impossible.

## Pattern Mapping: Java → Zig/Internal

| Java Pattern               | ClojureWasm Equivalent    | Zig Mechanism               |
| -------------------------- | ------------------------- | --------------------------- |
| `(System/nanoTime)`        | `(__nano-time)`           | `std.time`                  |
| `(System/currentTimeMillis)` | `(__current-time-millis)` | `std.time`                |
| `(System/getenv k)`        | `(__getenv k)`            | `std.process.getEnvMap`     |
| `(System/exit n)`          | `(__exit n)`              | `std.process.exit`          |
| `(Math/abs x)`             | `(abs x)`                 | `@abs`                      |
| `(Math/ceil x)`            | `(__ceil x)`              | `@ceil`                     |
| `(Math/floor x)`           | `(__floor x)`             | `@floor`                    |
| `(Math/round x)`           | `(__round x)`             | `@round`                    |
| `(Math/sqrt x)`            | `(__sqrt x)`              | `@sqrt`                     |
| `(Math/pow x y)`           | `(__pow x y)`             | `std.math.pow`              |
| `(Math/sin x)`             | `(__sin x)`               | `@sin`                      |
| `(Math/cos x)`             | `(__cos x)`               | `@cos`                      |
| `(Math/tan x)`             | `(__tan x)`               | `@tan`                      |
| `(Math/log x)`             | `(__log x)`               | `@log`                      |
| `(Math/exp x)`             | `(__exp x)`               | `@exp`                      |
| `(Math/random)`            | `(rand)`                  | builtin                     |
| `Math/PI`, `Math/E`        | constants                 | `std.math.pi`, `std.math.e` |
| `(.getMessage e)`          | `(ex-message e)`          | builtin                     |
| `(.getCause e)`            | `(ex-cause e)`            | builtin                     |
| `(Thread/sleep ms)`        | `(__sleep ms)`            | `std.time.sleep`            |
| `clojure.java.io/*`        | `slurp`/`spit`/etc.       | `std.fs`                    |

Syntax rewrite (F89): Analyzer should route `(System/*)` and `(Math/*)`
to internal `__` names automatically. Until then, `__` names work directly.

## Will Not Implement

- `reify`, `proxy`, `gen-class`, `gen-interface` — JVM bytecode generation
- `definterface`, `init-proxy`, `proxy-super` — proxy-dependent
- `Boolean/TRUE`, `Boolean/FALSE` — `true`/`false` suffice
- `clojure.lang.MapEntry.` — use `(vector k v)`
- `lock`, `unlock` — non-standard / JVM-dependent

## Development Principle

When encountering missing functionality:

1. **Implement properly** — add the builtin or .clj function
2. **Never use workarounds** as permanent solutions (temp stubs need F## tracking)
3. Check `vars.yaml` status before implementing (avoid duplicating done work)
4. If new Zig equivalent is needed, add builtin + register + update vars.yaml
