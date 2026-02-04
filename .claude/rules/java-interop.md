---
paths:
  - src/clj/**/*.clj
  - src/common/analyzer/**
  - src/common/builtin/**
---

# Java Interop Policy

**Do NOT skip features** that look JVM-specific. This table is NOT exhaustive.
When you encounter ANY Java interop pattern not listed here, investigate Zig
equivalents before concluding it's impossible.

## Decision Flow

```
1. Is it in "Will Not Implement" below?
   → Yes: skip. No: continue.
2. Is there a Zig stdlib equivalent? (std.fs, std.time, std.math, std.process)
   → Yes: implement as Zig builtin with __ prefix name.
3. Is it a threading/concurrency feature? (future, promise, ref, agent)
   → Yes: implement single-threaded simplified version (e.g., future=eager delay).
4. Is it a type conversion? (int, long, float, double, char, num)
   → Yes: implement as Zig builtin (cast/coerce).
5. Can pure Clojure implement it? (extend-protocol, macros, higher-order fns)
   → Yes: implement in .clj file.
6. None of the above?
   → Document limitation with F## entry. Do NOT silently skip.
```

## Known Patterns: Java → Zig/Internal

| Java Pattern                 | ClojureWasm Equivalent    | Zig Mechanism               |
| ---------------------------- | ------------------------- | --------------------------- |
| `(System/nanoTime)`          | `(__nano-time)`           | `std.time`                  |
| `(System/currentTimeMillis)` | `(__current-time-millis)` | `std.time`                  |
| `(System/getenv k)`         | `(__getenv k)`            | `std.process.getEnvMap`     |
| `(System/exit n)`           | `(__exit n)`              | `std.process.exit`          |
| `(Math/* x)`                | `(__sqrt x)` etc.         | `@sqrt`, `@sin`, `std.math` |
| `Math/PI`, `Math/E`         | constants                 | `std.math.pi`, `std.math.e` |
| `(.getMessage e)`           | `(ex-message e)`          | builtin                     |
| `(.getCause e)`             | `(ex-cause e)`            | builtin                     |
| `(Thread/sleep ms)`         | `(__sleep ms)`            | `std.time.sleep`            |
| `clojure.java.io/*`         | `slurp`/`spit`/etc.       | `std.fs`                    |

Syntax rewrite (F89): Analyzer should route `(System/*)` and `(Math/*)`
to internal `__` names automatically. Until then, `__` names work directly.

## Category Guidelines

| Category          | Approach                                | Example                        |
| ----------------- | --------------------------------------- | ------------------------------ |
| IO/File           | Zig builtin via `std.fs`                | slurp, spit, delete-file       |
| Math              | Zig builtin via `@intrinsic`/`std.math` | sqrt, sin, pow                 |
| Time/System       | Zig builtin via `std.time`/`std.process`| nano-time, exit, getenv        |
| Concurrency       | Single-threaded simplified              | future→delay, ref→atom, dosync→noop |
| Type conversion   | Zig builtin (cast/coerce)               | int, long, float, double       |
| Protocols         | Already supported (extend-type)         | extend, extend-protocol (.clj) |
| Hierarchy         | Zig builtin (global hierarchy map)      | derive, parents, ancestors     |
| Multimethods      | Already supported (both backends)       | prefer-method, get-method      |
| Exceptions        | Zig builtin                             | ex-cause, Throwable->map       |
| UUID/Random       | Zig builtin via `std.crypto`/`std.rand` | random-uuid, parse-uuid        |
| Bit ops           | Zig builtin (remaining)                 | bit-and-not, bit-set, bit-test |

## Will Not Implement

- `reify`, `proxy`, `gen-class`, `gen-interface` — JVM bytecode generation
- `definterface`, `init-proxy`, `proxy-super` — proxy-dependent
- `Boolean/TRUE`, `Boolean/FALSE` — `true`/`false` suffice
- `clojure.lang.MapEntry.` — use `(vector k v)`
- `lock`, `unlock` — non-standard / JVM-dependent

## Development Principle

- **Implement properly** — add the builtin or .clj function. Never use
  workarounds as permanent solutions (temp stubs need F## tracking).
- Check `vars.yaml` before implementing (avoid duplicating done work).
- This file lists known patterns only. **Unlisted ≠ skip.**
