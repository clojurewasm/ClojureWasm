---
paths:
  - src/**/*.zig
  - .dev/**/*.md
---

# No JVM-specific assumption

## Rule

cw v1 is not a JVM reimplementation. Comments and docs do not assume:

- Class hierarchy (cw has TypeDescriptor, not Class).
- Object header layout matching JVM (cw has its own packed header per
  ADR-0009).
- Bytecode generation (cw has Opcode enum, not JVM .class files).
- Thread monitor as built-in Object property (cw has heap-value-only
  lock per ADR-0009).

When comparing semantics, use phrases like "cw v1 implementation of
<Clojure semantics>", not "JVM-style <feature>".

## Why

- cw v1 design diverges from JVM internals while preserving Clojure
  observable semantics.
- JVM-style comments mislead later readers into Java assumptions.
- ADRs anchor each divergence with a rationale.

## How to apply

- Write semantics references against Clojure (clojure.core,
  clojure.lang) rather than JVM bytecode.
- For cw-specific implementation choices, reference the ADR.
- For JVM contrast, label clearly: "JVM Clojure does X here; cw v1 does
  Y per ADR-NNNN".
