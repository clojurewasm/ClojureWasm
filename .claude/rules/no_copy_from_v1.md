---
paths:
  - src/**/*.zig
  - bench/fixtures/**
  - test/**
---

# No verbatim copy from cw v0

## Rule

Do not copy cw v0 (`~/Documents/MyProducts/ClojureWasm/`) code verbatim.
Read v0 as a read-only reference and re-derive semantics in Zig 0.16
idiom.

## Why

- cw v0 carries 89K LOC of accumulated technical debt
  (collections.zig at 6,269 lines, std.Io F140-F144 disabled features).
- v0 implementation patterns assume different tier classifications
  (cw v1 uses Option β; v0 used Tier D for the class system).
- cw v1 is a re-design, not a port; verbatim copy preserves the original
  design pressure.

## How to apply

At each Phase Step 0 (textbook_survey):

1. Read v0 source for context (read-only).
2. Re-implement the same semantics in cw v1 Zig 0.16 idiom.
3. In per-task notes, record both "what v0 did" and "what cw v1 does",
   with rationale for differences.

When the v0 and cw v1 choices match, the rationale must explain "why the
same choice", not assume it.

When they differ, an ADR justifies the divergence.

## Counter-example

Avoid: `cp ~/Documents/MyProducts/ClojureWasm/src/lang/builtins/collections.zig src/runtime/collection/vector.zig`

Do instead: Read v0 collections.zig persistent vector section, understand
HAMT shift=5 + tail array design (per ADR-0007 TypeDescriptor and
ADR-0012 ValueTag), re-implement in cw v1.
