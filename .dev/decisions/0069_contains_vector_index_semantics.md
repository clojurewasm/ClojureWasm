# ADR-0069 — `contains?` on a vector matches JVM index semantics (reverse DIVERGENCE D1)

- **Status**: Proposed → Accepted (2026-06-02)
- **Supersedes**: DIVERGENCE D1 in `lang/primitive/collection.zig::containsQFn`
  (the Phase-6.16 "reject vector contains? as a cleaner set/map-only semantic"
  note + its locking unit test).
- **Related**: F-011 (behavioural equivalence with `clj`), F-010 (run real
  Clojure libraries), F-002 (finished-form wins), `no_jvm_specific_assumption.md`,
  ADR-0059 (no-JVM-Class surface divergences). Surfaced by the `clojure.data/diff`
  clj-diff sweep.

## Context

`(contains? coll k)` carried **DIVERGENCE D1**: cljw rejected
`(contains? [1 2 3] 1)` with `type_error`, on the rationale that JVM Clojure's
"vectors test index-membership" is a documented newcomer footgun and a
"cleaner set/map-only semantic" was preferable. A unit test locked this
(`expectError(error.TypeError, ...)`).

D1 was written in Phase 6.16, **before F-011** (2026-05-31) made behavioural
equivalence with `clj` project law. JVM Clojure: `(contains? [1 2 3] 1)` → `true`,
`(contains? [1 2 3] 5)` → `false`, `(contains? [1 2 3] :x)` → `false` — a pure
**index-validity** predicate (`integer?(k) ∧ 0 ≤ k < count`), never throwing.

The `clojure.data/diff` sweep made the conflict concrete: `diff`'s sequential
path calls `(contains? shorter-vector out-of-range-index)` and **requires it to
return `false`, not throw**. Under D1, real `clojure.core`-shape code cannot run
— directly blocking F-010's named engine (running real libraries through cljw).

## Decision

Reverse D1. `contains?` on a vector tests index validity exactly as JVM:
integer `k` in `[0, count)` → `true`; non-integer or out-of-range → `false`;
never throws. Set / map / sorted / Associative-protocol semantics are unchanged.

The footgun is inherited deliberately: it is *documented Clojure behaviour*, and
F-011 prioritises observable equivalence (including the gotchas) over an
implementer's judgment that the semantic "should" be cleaner.

## Why D1 was not a legitimate divergence under F-011

F-011 permits a deliberate surface divergence only when it is **forced by a
no-JVM necessity** (e.g. `(class 5)` → `Long` not `java.lang.Long`, ADR-0059 —
there is no `java.lang.Long` to name). `contains?` on a vector needs **zero JVM
internals**: it is a pure integer-range check. D1 was a *judgment-divergence*
("we disagree with the JVM semantic"), which is exactly the category F-011's
equivalence mandate overrules. Per the priority chain (F-NNN > ADR/rule), the
older D1 implementation decision is edited to align with F-011, never the reverse.

## Alternatives considered

(Devil's-advocate subagent, fresh context, briefed with F-002/F-010/F-011.)

- **Alt 1 (smallest-diff) — VIOLATES F-011, recorded not selectable**: keep D1
  throwing publicly, special-case `clojure.data/diff` with a private non-throwing
  index check. Better: zero change to `contains?`. Breaks: a direct F-011
  violation (observable `(contains? [1 2 3] 1)` still diverges with no no-JVM
  forcing fact); a lie-by-construction (public vs internal predicate disagree);
  every other library using `(contains? vec i)` still breaks → F-010 whack-a-mole
  forever; two semantics for one op → rot (F-010 refactor gate). Listed only
  because the brief requires a smallest-diff entry.
- **Alt 2 (finished-form-clean) — CHOSEN**: delete D1, full JVM-faithful index
  semantics, record the reversal as this ADR, add the canonical exprs +
  `clojure.data/diff` to the clj corpus. Better: satisfies F-011; unblocks F-010
  + `clojure.data/diff`; removes the two-semantics rot; closes a footgun-blocker
  as a corpus-backed area. Breaks: reintroduces the genuine Clojure footgun — but
  that is *fidelity*, not a defect; requires inverting the D1 test. No F-NNN
  violated.
- **Alt 3 (wildcard)**: Alt 2 + an opt-in, non-semantic lint/warning flagging
  `(contains? <literal-vec> <literal-int>)` to protect newcomers. Better: full
  Alt-2 win plus captures D1's footgun-protection *intent* in a layer that never
  alters return values; points at cljw's tooling story. Breaks: invents a lint
  subsystem with its own design surface (false positives on macro-expanded code,
  JIT interaction) — scope creep. Deferred to a `debt.md` row at the Phase that
  owns dev-tooling, not bundled here.

DA recommendation: Alt 2. Main loop concurs — F-011 is dispositive and F-010
sharpens "should" to "must"; the lint idea is filed for later, not built now.

## Consequences

- `containsQFn` gains a `.vector` arm (index-validity, no throw).
- The D1 unit test inverts from "asserts throw" to "asserts true/false/false".
- The D1 doc-comment is replaced by a reference to this ADR.
- `clojure.data/diff` (and any real library using `(contains? vec i)`) now runs.
- 3 differential test cases (shared by both backends) + the `data_diff` corpus
  lock the equivalence; corpus regression re-checks it every gate.
- Follow-up (deferred, not this cycle): the Alt-3 footgun lint — file when a
  dev-tooling/diagnostics Phase opens.
