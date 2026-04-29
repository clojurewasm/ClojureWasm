# 0002 — Phase 3 exit smoke uses an integer placeholder for `ex-info` data; map literals stay in Phase 5

- **Status**: Accepted
- **Date**: 2026-04-27
- **Author**: Shota Kudo
- **Tags**: roadmap-amendment, scope, phase-3, phase-5, ex-info, map-literal

## Context

ROADMAP §9.5 task 3.14 (Phase-3 exit smoke) was originally written as:

> `(try (throw (ex-info "boom" {})) (catch ExceptionInfo e (ex-message e)))` → `"boom"`

Implementation of Phase 3 surfaced two facts that the original wording
did not anticipate:

- `{}` (the empty map literal) is **not** parsed-and-analysed today.
  `src/eval/analyzer.zig:212` raises `not_implemented` with the message
  *"Map literal as expression value not yet supported (Phase 3+)"*.
- ROADMAP §9 phase table line 644 scopes **collections (HAMT, Vector)
  + Mark-Sweep GC** to **Phase 5**. The same table line 642 frames the
  Phase 3 exit at the high level as `(defn f [x] (+ x 1)) (f 2) → 3;
  try/catch works` — i.e. the Phase 3 high-level row never required
  map literals.

So §9.5 / 3.14's `{}` was a **drafting overreach** at ROADMAP-creation
time: the detailed task row demanded a feature whose implementation
was assigned to a phase two phases away. The Phase 3 high-level exit
(line 642) and the Phase 5 scope (line 644) were already internally
consistent; only the §9.5 / 3.14 detail line disagreed with both.

This is exactly the kind of mismatch ROADMAP §17 (Amendment policy)
is designed for. This ADR follows the §17.2 four-step amendment.

## Decision

- **D-A**: Phase 3's exit smoke uses `(ex-info "boom" 0)` — an integer
  placeholder for the `data` argument — instead of `(ex-info "boom"
  {})`. The smoke's purpose is to verify the **try/throw/catch +
  ex-info round-trip semantics** end-to-end; `ex-info`'s data slot is
  polymorphic, so any non-nil Value works as a placeholder. The
  semantics being verified are unchanged.
- **D-B**: Map literal support stays scoped to Phase 5 alongside the
  rest of HAMT / persistent-map work. We do **not** ship a minimal
  empty-map stub during Phase 3; that would add a new heap tag, a
  printValue arm, an equality + hash branch, and a deinit path purely
  to satisfy a smoke string, with no follow-on consumer in Phase 3.
  ROADMAP §2 P4 (no ad-hoc patches) and P3 (core stays stable) both
  push toward "do it properly when Phase 5 actually arrives."

§9.5 / 3.14 is rewritten in place to use the integer placeholder. A
trailing parenthetical points to this ADR for cause.

## Alternatives considered

### Alternative A — Add minimal empty-map literal support in Phase 3

- **Sketch**: add a `heap_map` HeapTag, allocate a sentinel empty-map
  Value, support analyser routing `{}` → that Value, render it in
  `printValue`, and stub equality / hash. ~80–120 LOC. The full HAMT
  structure still lands in Phase 5 — Phase 3 would only support `{}`
  and rely on Phase 5 to extend.
- **Why rejected**: This is a P4 (no ad-hoc patches) violation. A
  partially-implemented heap_map with one literal shape would have to
  be revisited at Phase 5 anyway, with the risk that Phase 5 inherits
  a brittle stub instead of a clean greenfield. The smoke verifies
  try/catch semantics, not collection semantics; using a stand-in for
  the data slot is sufficient and honest.

### Alternative B — Loosen the smoke to accept any data Value

- **Sketch**: write the smoke as "any non-nil data argument works" and
  let the implementer choose. Document the substitution in the smoke
  script comments only, not in ROADMAP.
- **Why rejected**: ROADMAP is the SoT (§17.4). A "your choice" exit
  form invites future drift — six months from now nobody can tell
  whether the substitution was deliberate or a bug. Making the choice
  explicit in ROADMAP + documenting the why in this ADR keeps the
  trail readable.

### Alternative C — Defer the ex-info smoke entirely to Phase 5

- **Sketch**: Phase 3 only verifies `(defn f [x] ...) (f 2) → 3`;
  ex-info smoke moves to Phase 5 alongside `{}`.
- **Why rejected**: ex-info itself (the heap struct, `ex-message` /
  `ex-data` builtins, `try/catch ExceptionInfo` evaluation) shipped in
  §9.5 tasks 3.10 + 3.11 and works today. The semantic surface is
  Phase-3-complete; only the literal `{}` was misdrafted. Pushing the
  whole smoke to Phase 5 would lose end-to-end verification of
  Phase-3-shipped behaviour for two phases.

## Consequences

- **Positive**:
  - ROADMAP self-consistency is restored: §9.5 / 3.14 detail row now
    agrees with the §9 phase table (line 642 high-level Phase 3 exit;
    line 644 Phase 5 collections scope).
  - The smoke is implementable today without scope creep into
    collection work.
  - `ROADMAP §17` (Amendment policy) gets its first real exercise,
    establishing the practice of "amend in place + ADR + handover sync
    + commit reference."

- **Negative**:
  - The smoke's `data` argument differs cosmetically from idiomatic
    Clojure (`{}` would be the natural empty case). Anyone porting a
    Phase-5 example into the Phase-3 smoke needs to remember the
    substitution.

- **Neutral / follow-ups**:
  - When Phase 5 lands map literals, the §9.6+ task list should
    include a sweep to (a) optionally update §9.5 / 3.14 to the
    canonical `{}` form, and (b) add a Phase 5 exit case that uses
    `(ex-info "..." {:k v})` to verify map literal + ex-info compose.
    A pointer to this ADR goes in the §9.6 task notes.
  - This ADR is also the **first §17.2 four-step amendment**; it
    incidentally validates that the policy is workable.

## References

- ROADMAP §9 phase table (lines 638–660) — Phase 3 (line 642), Phase 5
  (line 644).
- ROADMAP §9.5 / 3.14 — the amended row.
- ROADMAP §17 — Amendment policy (introduced in the same commit as
  this ADR).
- ROADMAP §2 P3 (core stays stable), P4 (no ad-hoc patches).
- `src/eval/analyzer.zig:212` — current `not_implemented` site for map
  literals.
- Original wording (preserved for trace):
  `(try (throw (ex-info "boom" {})) (catch ExceptionInfo e (ex-message e)))` → `"boom"`
- New wording:
  `(try (throw (ex-info "boom" 0)) (catch ExceptionInfo e (ex-message e)))` → `"boom"`
- Related ADRs: 0001 (macroexpand routing — same pattern of "deferred
  decision surfaces during implementation").
