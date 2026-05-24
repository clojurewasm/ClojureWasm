# 0030 — Defer 5.12.b (defrecord) + 5.12.c (reify) to Phase 7 entry

- **Status**: Accepted
- **Date**: 2026-05-24
- **Author**: Shota Kudo (drafted by the autonomous loop with Devil's-advocate fork)
- **Tags**: phase-5, phase-7, scope, deftype, defrecord, reify, protocol-dispatch

## Context

ROADMAP §9.7 row 5.12 originally bundled `deftype` + `defrecord` +
`reify` (all three of ADR-0007 Option β's user-facing forms) into a
single Phase-5 deliverable. 5.12.a landed `deftype` + constructor +
field access against the TreeWalk backend at commit 7e7c6fd.

The remaining halves of the row — `defrecord` (5.12.b) and `reify`
(5.12.c) — are **protocol-method-dispatch consumers**:

- `defrecord` extends `deftype` with implicit `IPersistentMap`
  semantics (`get` / `assoc` / `keys` / `vals` over field names).
  Either it special-cases these four methods in eval/tree_walk
  (skeleton; would be rewritten when Phase 7's dispatch lands), or
  it uses `TypeDescriptor.lookupMethod` directly without the
  CallSite-cache-driven dispatch.
- `reify` produces an anonymous TypeDescriptor whose method bodies
  close over the surrounding lexical scope. Its only user-facing
  purpose **is** protocol-method dispatch — without that, `reify`
  has no semantics to honour.

Phase 7 entry per ADR-0008 amendment 1 will land the canonical
`dispatch(rt, cs, receiver, protocol, method, args)` function, the
CallSite cache fill / hit signature, and the
`MethodEntry.fn_ptr` calling convention (Caller-context threading,
arg adapter, error path). All three are open design questions today.

Landing `defrecord` and `reify` against today's pre-dispatch
machinery commits cw v1 to a Phase-5 shape that will almost
certainly be rewritten when Phase 7 ABI is decided — a textbook
Progress-pressure smell + Skeleton-with-no-shrink smell per
`.dev/principle.md`.

## Decision

ROADMAP §9.7 row 5.12 is narrowed to scope = **`deftype` only**
(already landed as 5.12.a). Two new sub-tasks are added to ROADMAP
§9.9 Phase 7 entry alongside 5.12.d:

- **5.12.b** (defrecord) — deftype + implicit IPersistentMap
  semantics, written against the Phase-7 dispatch ABI.
- **5.12.c** (reify) — anonymous TypeDescriptor + closure capture
  + protocol-method bodies, written against the Phase-7 dispatch
  ABI.

`Code.feature_not_supported` continues to raise for `(defrecord
…)` / `(reify …)` at Phase 5 exit. The `phase_at_least_5` flip
(5.15) does **not** flip these.

## Alternatives considered

Per CLAUDE.md § ADR-level designs are handled inline, a
Devil's-advocate `general-purpose` subagent was forked with the
F-NNN constraints in context (`.dev/project_facts.md` F-001..F-009)
to produce alternatives within the F-NNN envelope.

### Alt 1 — Smallest-diff: land defrecord + reify in Phase 5 with pre-dispatch shims

`defrecord` lands as `deftype` + hard-coded IPersistentMap method
table via direct `TypeDescriptor.lookupMethod` (5.11 surface).
`reify` lands as anonymous TypeDescriptor + direct lookup. Phase 7
rewires direct lookup through `dispatch + CallSite`; `reify`'s
protocol-method bodies are rewritten.

- **Better**: ROADMAP §9.7 spine stays whole; Phase 5 exit smoke
  can include `defrecord` and `reify` cases beyond the listed
  `(deftype Point [x y])` example; Phase 7 entry stays slim.
- **Worse**: explicitly accepts a Phase-7 rewrite of `reify`'s
  method-body codegen (F-002 says smallest-diff is secondary, this
  alternative buys Phase-5 width by accepting that rewrite).

**Rejected** — F-002 + F-003 prefer landing once against the real
ABI.

### Alt 2 — Defer defrecord + reify, narrow 5.12 to 5.12.a (this ADR)

ROADMAP §9.7 5.12 = deftype only. 5.12.b + 5.12.c move to Phase 7
entry next to 5.12.d (protocol method dispatch).

- **Better**: defrecord's IPersistentMap path and reify's protocol
  bodies land once, against the real CallSite ABI. Aligns with F-003
  (defer to owning Phase) — both forms *are* protocol-dispatch
  consumers.
- **Worse**: Phase 5 ships with `defrecord` / `reify` still raising
  `Code.feature_not_supported`. Phase 7 entry grows by 2 tasks.

**Accepted**.

### Alt 3 — Wildcard: defer only reify, land defrecord in Phase 5 (no protocol bodies)

`defrecord`'s required Phase-5 surface is the implicit map view
(get/assoc/keys/vals) — no user-defined protocol methods needed.
Land 5.12.b with that narrow scope; defer 5.12.c (reify).

- **Better**: defrecord becomes usable at phase_at_least_5 (5.15)
  flip, broader Tier A coverage. get/assoc reuse 5.4-5.6 map
  machinery, no dispatch ABI dependency.
- **Worse**: defrecord's `(defrecord R [x] Proto (m [_] …))`
  extended form still raises feature_not_supported until Phase 7,
  creating a "half-supported" surface that the Skeleton-with-no-
  shrink smell would flag.

**Rejected** — F-002 finished-form purity prefers Alt 2.

## Consequences

### Positive

- 5.12.b and 5.12.c land once, against the Phase-7 dispatch ABI.
  No rewrite cost on the protocol-method-body codegen path.
- F-003 honoured: `defrecord` and `reify` are protocol-dispatch
  consumers; their owner is the Phase that lands the dispatch ABI.
- Phase 5 exit smoke (5.16) keeps the listed
  `(deftype Point [x y]) (.x (Point. 1 2))` example, which is the
  only test the original ROADMAP §9.7 5.16 row spelled out for the
  ADR-0007 family.

### Negative

- Phase 5 exits with `defrecord` and `reify` still raising
  `Code.feature_not_supported`. Tier A coverage at the 5.15 flip
  is narrower than the original §9.7 5.12 row implied.
- Phase 7 entry grows by 2 tasks (5.12.b + 5.12.c alongside the
  already-planned 5.12.d).
- Tests using `defrecord` / `reify` (none in the current corpus
  but the Phase 11 `test/clj/` port may surface some) stay on the
  unsupported path until Phase 7.

### Neutral / follow-ups

- ROADMAP §9.7 5.12 description amended in-place to scope =
  deftype only, with a one-line note pointing at this ADR.
- ROADMAP §9.9 Phase 7 entry placeholder gets 5.12.b + 5.12.c +
  5.12.d as three explicit task rows (the 4.21 / ADR-0007 Phase 5+
  migration note in §9.9 already foreshadows this).
- `.dev/debt.md` D-041 (catalog Code cleanup) is unaffected.

## References

- ROADMAP §9.7 row 5.12 (amended in same commit).
- ROADMAP §9.9 Phase 7 entry placeholder (amended in same commit).
- ADR-0007 (TypeDescriptor / Option β).
- ADR-0008 a1 (protocol method dispatch contract).
- F-003 (defer to owning Phase) + F-002 (finished-form wins).
- 5.12.a landing commit: 7e7c6fd.
- Devil's-advocate subagent output: see Alternatives considered
  above (recorded inline per CLAUDE.md § ADR-level designs are
  handled inline).

## Revision history

- 2026-05-24: Status: Proposed → Accepted (initial landing).
  Devil's-advocate subagent forked with F-NNN context; output
  reflected verbatim in Alternatives considered.
