# 0006 — Defer Wasm FFI to Phase 16 via the Pod boundary

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, wasm, scope, deferred, pod-boundary

## Context

cw v0 bundled a "Clojure runtime" and a "Wasm host" into the same
binary. The `cljw.wasm` namespace exposed 17 Wasm-host vars; the
runtime had to initialize zwasm v1, manage GC finalizers for Wasm
modules, and carry `wasm_module` / `wasm_fn` GC types. The complexity
contributed to the bootstrap fragility and the std.Io migration outage
(F140-F144).

zwasm v2 is still stabilizing (Phase 9, Windows reconcile in flight),
so coupling cw v1 to it now would replay v0's pain.

## Decision

cw v1 does not implement Wasm FFI from Phase 4 through Phase 15. The
build flag `-Dwasm=false` is the default, the `cljw.wasm` namespace is
absent, and zwasm is not a dependency. Phase 4 task 4.16 operationalizes
the removal.

Phase 16 reintroduces Wasm capability via a Pod boundary (out-of-process
or sandboxed in-process module) once zwasm v2 is stable.

Re-introduction conditions (evaluated at Phase 16 entry):

1. zwasm v2 has reached Wasm 3.0 100% PASS on three platforms (Mac
   aarch64, Linux x86_64, Windows x86_64).
2. A Pod protocol design is settled (Babashka-style is the leading
   candidate; ADR-0015 upstream reference policy may also influence
   this).
3. cw v1 has reached Tier B with `clojure.data.json` and friends, so
   the I/O surface is mature enough to wrap a Pod.

## Alternatives considered

### Alternative A — Keep the cw v0 path

- **Sketch**: continue bundling zwasm and the `cljw.wasm` namespace.
- **Why rejected**: the bootstrap complexity that triggered the v0
  std.Io outage would persist.

### Alternative B — Permanent removal (Tier D for Wasm)

- **Sketch**: declare Wasm out of scope forever.
- **Why rejected**: ROADMAP §8 still includes Wasm as a v0.2 ambition.

### Alternative C — Lightweight bundled Wasm runtime (no zwasm dependency)

- **Sketch**: implement a minimal Wasm interpreter inline.
- **Why rejected**: scope creep against the Phase 4-15 plan.

## Consequences

- **Positive**: bootstrap complexity drops sharply. The F140-F144
  class of regression cannot recur for Phase 4-15.
- **Negative**: Wasm-flavored learning material is delayed until
  Phase 16+.
- **Neutral / follow-ups**: Phase 16 entry ADR defines the Pod
  protocol concretely.

## References

- ROADMAP §3.2 (Wasm scope)
- ROADMAP §8 (Wasm / edge strategy)
- ROADMAP §9.6 task 4.16 (operationalize the removal)
- cw v0 disabled features F140-F144 as cautionary precedent

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
- 2026-05-23 (amendment 3): **Wasm FFI is confirmed unavoidable; zwasm v2
  is the target counterparty.** User direction (2026-05-23) clarified
  that cw v2 will integrate with `zwasm_from_scratch` (zwasm v2 — still
  in development) and that wasm FFI is "an indispensable element".
  zwasm v2 itself provides JIT and memory management. Implications:
    - The "Pod boundary" framing in §Decision remains the default
      *protocol shape*, but the **inline-vs-Pod choice is reopened**
      at Phase 16 entry. If inline (NaN-box-tagged) wasm Values are
      chosen, the slots released by amendment 1 (`big_int` / `ratio`
      now at 29 / 30) cannot be reclaimed — Phase 16 must mint fresh
      slots, co-ordinated with D-027 (NaN-box layout 第二世代).
    - The cw v2 Phase 5 mark-sweep GC and the cw v2 Phase 17 JIT
      (ADR-0005 3rd backend) **overlap territorially** with zwasm v2's
      own GC and JIT. Phase 16 entry resolves the heap-boundary and
      JIT-coordination design (separate cw-heap vs wasm-heap, JIT
      compilation handoff, etc.).
    - The Phase 16 re-introduction-conditions list in §Decision
      should be re-read with zwasm v2's actual progress in mind, not
      v1's. Specifically, condition 1 ("zwasm v2 has reached Wasm
      3.0 100% PASS on three platforms") is the gating signal cw v2
      monitors.
  Recorded as debt D-036 for the Phase 16 entry owner.
- 2026-05-23 (amendment 2): **`-Dwasm=false` build option reverted.**
  D-028 audit found the option had no consumer — the cw-from-scratch
  branch never carried the wasm FFI surface this option was meant to
  gate. Phase 16 re-introduction (per the Pod boundary plan above)
  mints its own build option at that time. The 4.16 ROADMAP row stays
  as a record of the revert; no source surface remains.
- 2026-05-23 (amendment 1): **NaN-box slots for `wasm_module` /
  `wasm_fn` are released and re-purposed for `big_int` / `ratio`**
  (ADR-0012 amendment 1). Rationale: Phase 16 reintroduces Wasm via
  a Pod boundary (out-of-process or sandboxed in-process), which
  exposes Wasm modules as opaque host values rather than
  NaN-box-tagged inline pointers. The day-1 reservation made sense
  while a bundled Wasm runtime was on the table; with the Pod
  boundary, Phase 16 can mint fresh slots if (and only if) the Pod
  protocol decides to surface Wasm modules as first-class cw
  Values. Releasing the slots now lets Phase 4 close `big_int` (and
  reserve `ratio`) at their natural NaN-box position rather than the
  PHASE4_PLACEHOLDER_TAG smell that 4.23 entry shipped at
  commit df6958f.
