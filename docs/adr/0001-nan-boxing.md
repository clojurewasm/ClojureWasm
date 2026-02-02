# ADR-0001: Tagged Union First, NaN Boxing Later

## Status

Accepted

## Context

ClojureWasm needs a runtime Value representation. Two main strategies exist:

1. **Tagged union** — A standard Zig `union(enum)` with explicit tag byte.
   Simple to debug, works on all targets (native and Wasm), matches Beta's
   proven approach (28+ variants, 1036 tests, 545 functions).

2. **NaN boxing** — Pack type tag into the unused bits of an IEEE 754 NaN.
   Gives a uniform 8-byte representation, avoids pointer indirection for
   small values, and enables faster dispatch. However, it only benefits
   the native track (Wasm has its own typed value model).

The production design (.dev/future.md SS5, SS7) specifies NaN boxing for native
and tagged union for wasm_rt, selectable via comptime. The question is
when to introduce NaN boxing.

## Decision

Start with a tagged union for all tracks. Defer NaN boxing to a dedicated
optimization phase (planned: Phase 4) after the VM, builtins, and test
suite are stable.

## Rationale

- **Correctness first**: A tagged union is straightforward to debug. NaN
  boxing introduces subtle bit-manipulation bugs that are hard to diagnose
  alongside a new reader, analyzer, and VM.
- **Dual-track compatibility**: The tagged union works identically on native
  and wasm_rt. NaN boxing is a native-only optimization.
- **Beta precedent**: Beta shipped with a tagged union and passed all tests.
  The limitation was maintenance cost at scale, not correctness or performance.
- **Clean switchover**: By keeping Value access behind accessor functions from
  day one, NaN boxing can be introduced as a comptime alternative without
  changing any call sites.

## Consequences

- Initial native performance will be comparable to Beta (no NaN boxing gains).
- The Value type must expose accessors (not raw field access) so that NaN
  boxing can be swapped in transparently.
- Phase 4 will introduce NaN boxing with before/after benchmark comparison
  to measure actual gains.

## Alternatives Considered

- **NaN boxing from the start**: Rejected. Adds complexity to the critical
  early phases where correctness of reader/analyzer/VM is the priority.
- **Separate Value types per track from the start**: Rejected. Premature
  abstraction; the tagged union serves both tracks adequately for now.

## References

- .dev/future.md SS3, SS5, SS7 (Value representation, GC, dual-track)
- .dev/notes/decisions.md D1
