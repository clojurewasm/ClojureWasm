# 0013 — Tier D forms and packages are permanently excluded

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, tier-d, compat, scope, java-interop

## Context

cw v0 carried an implicit "55 vars excluded" line that drifted across
the codebase and `DIFFERENCES.md`. Without a tier ADR, every new
arrival had to re-derive the rationale, and the ad-hoc list grew
ambiguous boundaries. The corpus audit clarified that the genuinely
non-portable set is small.

## Decision

cw v1 declares the following as Tier D — permanently excluded from
the supported surface. Adding any of these later requires a MAJOR
release (per ROADMAP §1.4 SemVer rule) and an amendment to this ADR.

### Excluded special forms (5)

- `gen-class` — requires JVM Class system and bytecode emission.
- `gen-interface` — same.
- `clojure.core/compile` — JVM .class file emission, out of cw scope.
- `proxy` when targeting deep Java extension (Apache HC base classes,
  Swing GUI base classes, `java.util.logging.Formatter / Handler`
  bases). Approximately 35-50 of 392 corpus `proxy` occurrences fall
  here. The remaining ~340 uses are reached through `reify` against
  cw-native protocols.
- `bean`'s reflection-deep variant. The basic field walk for a
  cw-native type stays Tier C and goes through `TypeDescriptor`.

### Excluded Java packages (~480 classes)

- `java.awt.*` — GUI, out of cw scope.
- `javax.swing.*` — GUI, out of cw scope.
- `java.applet.*` — deprecated, out of cw scope.
- Deep reflection internals (parts of `java.lang.reflect.*` beyond
  what `TypeDescriptor` exposes).

### Error message contract

Tier D entries raise `Code.tier_d_form` (per ADR-0018) with the
specific form name supplied via `.{ .name = "<form>" }`. The
user-facing message is:

```
<form> is not part of ClojureWasm
```

The tier classification ("D") and the rationale ADR ("ADR-0013")
are development artifacts; they do not appear in the user-facing
text. `scripts/check_tier_d_error_msg.sh` (informational at Phase 4
entry, gate at Phase 5+) checks that every Tier D form named in
`compat_tiers.yaml` raises through the catalog rather than a
hand-written `setErrorFmt` call.

## Alternatives considered

### Alternative A — Defer the Tier D decision indefinitely

- **Sketch**: leave it to per-feature ADRs.
- **Why rejected**: the ad-hoc accumulation is what bit cw v0. A
  central list is the cheaper option.

### Alternative B — Tier D for a larger set (cw v0 "55 vars")

- **Sketch**: also exclude all class-system forms, STM, locking,
  threading.
- **Why rejected**: corpus measurement shows these have thousands of
  uses; excluding them removes cw from the Clojure ecosystem.

## Consequences

- **Positive**: a small, defensible Tier D list — five forms plus the
  GUI / applet packages — leaves cw v1 compatible with the vast
  majority of pure-Clojure code that exists today.
- **Negative**: programs that genuinely need bytecode emission or
  Swing UI will not run, no matter how clever the cw runtime gets.
- **Neutral / follow-ups**: `compat_tiers.yaml` carries the
  enumerated lists. `tier_classification.md` rule covers the
  error-message format.

## References

- ROADMAP §3.2 (Out-of-scope), §6 (Tier system data-driven)
- `compat_tiers.yaml` (authoritative list)
- Related ADRs: 0007, 0011

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
- 2026-05-23 (amendment): Error message contract rewritten. The
  `"Tier D: <reason>, see ADR-0013"` template is replaced by catalog
  `Code.tier_d_form` (ADR-0018) whose user-facing output is
  `"<form> is not part of ClojureWasm"`.
