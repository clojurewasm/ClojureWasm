# 0031 — Regex engine choice for ClojureWasm

- **Status**: Proposed (Devil's-advocate alternatives pending)
- **Date**: 2026-05-25
- **Author**: Shota Kudo (drafted by the autonomous loop;
  Devil's-advocate fork scheduled for next session before
  `Status: Accepted`)
- **Tags**: phase-6, regex, dependency, java-pattern, exit-criterion

## Context

ROADMAP §9.8 row 6.6 calls for
`runtime/regex/{compile,match}.zig` +
`runtime/java/util/regex/Pattern.zig` +
`lang/primitive/regex.zig` so the Phase 6 exit criterion
`(re-find #"\d+" "abc123")` → `"123"` is met. The regex
literal reader (`#"..."`) already lands a `regex` Tag Value
(Phase 4); only the engine + matcher is missing.

JVM Clojure delegates entirely to `java.util.regex.Pattern`.
That is one of the largest single dependencies in Clojure
core's IFn surface — `re-find` / `re-matches` / `re-seq` /
`re-groups` / `replace` / `split` all flow through it. The
cw v1 engine has to cover at minimum:

- Character classes (`\d`, `\w`, `\s`, `[a-z]`, `[^abc]`).
- Quantifiers (`?`, `*`, `+`, `{n,m}`, lazy `*?` `+?`).
- Anchors (`^`, `$`, `\b`).
- Grouping (`(...)`, `(?:...)`, `(?<name>...)`).
- Alternation (`|`).
- Java-compatible backslash escapes and `(?i)` flag.

The decision is which engine to ship.

## Decision (provisional)

**TBD — pending Devil's-advocate subagent fork.** The
autonomous loop drafts this skeleton and the next session
forks a `general-purpose` subagent with the brief below
before flipping `Status: Accepted`.

### Candidate engines

| Engine                               | Pros                                                                                                 | Cons                                                                                                                                 |
|--------------------------------------|------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| **A. Custom-min (in-tree Zig)**      | Zero dependency. Fits F-001 (zwasm v2 standalone). Matches deftype/numeric tower in-tree philosophy. | Re-implementing Java's Pattern surface is a large engineering bill. Subtle semantic gaps surface as conformance test failures later. |
| **B. zig-regex (3rd-party)**         | Already exists; saves ~1500 LOC. Active maintenance.                                                 | New dependency, Zig 0.16 compat unknown; PCRE-ish syntax may diverge from Java's; would need a syntax-translation layer.             |
| **C. PCRE C bind via build.zig.zon** | Most feature-complete; near-direct mapping to Java's Pattern.                                        | C dependency violates F-001 zwasm v2 standalone goal. Wasm Component target (Phase 19) is complicated by it.                         |

### Devil's-advocate brief (paste into next session's subagent fork)

> Devil's advocate this ADR. The active F-NNN constraints from
> `.dev/project_facts.md` are:
>
> - F-001: zwasm v2 standalone (no JVM runtime dep).
> - F-002: finished-form-clean wins over smallest-diff.
> - F-009: feature-implementation neutral (impl in
>   runtime/regex/, Java surface in runtime/java/util/regex/,
>   Clojure peer in lang/primitive/regex.zig).
>
> Produce 3 alternative shapes **within those constraints**
> (one smallest-diff, one finished-form-clean, one wildcard);
> for each, name what it does better than candidates A / B / C
> and what it breaks. Do NOT propose alternatives that violate
> F-001 (no C deps, no JVM deps). If the only finished-form-
> clean option requires violating F-001, record that finding
> as the leading entry of Alternatives considered so the main
> loop sees it, but do not ask the loop to halt — F-NNN
> amendment is a user action.

The subagent's output is reflected verbatim into the
"Alternatives considered" section below before the next
session flips `Status: Accepted`.

## Alternatives considered

*(populated by next session's Devil's-advocate subagent)*

## Consequences (provisional)

Depending on the engine chosen, Phase 6.6 implementation work
is:

- Candidate A: 800-1500 LOC across `runtime/regex/`,
  spread over 3-5 cycles.
- Candidate B: 200-400 LOC for the bind + syntax translation,
  1-2 cycles, plus a `build.zig.zon` edit and the Wasm
  Component compat note.
- Candidate C: 100-200 LOC for the cgo-ish bind, 1 cycle —
  but F-001 conflict.

Once accepted, the regex Tag's `Value` extracts pattern bytes
and engine state through `runtime/regex/compile.zig` ;
`re-find` / `re-matches` / `re-seq` / `replace` / `split`
flow through `runtime/regex/match.zig` and surface in
`lang/primitive/regex.zig`. The Java surface
`runtime/java/util/regex/Pattern.zig` is a thin Backend
marker (`impl-only`) per ADR-0029 D4.

## Affected files (provisional)

- `runtime/regex/compile.zig` (new)
- `runtime/regex/match.zig` (new)
- `runtime/java/util/regex/Pattern.zig` (new)
- `lang/primitive/regex.zig` (new)
- `compat_tiers.yaml` (new fqn entry: `java.util.regex.Pattern`)
- `build.zig.zon` (if candidate B accepted)
- `lang/bootstrap.zig` (register the new primitives)

## Revision history

- 2026-05-25 (this skeleton): Drafted Proposed-status. Body
  populated except for the Devil's-advocate subagent output.
  Next session forks the subagent, fills "Alternatives
  considered", and flips to Accepted before any implementation
  code lands.
