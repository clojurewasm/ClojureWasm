# 0052 — Universal `=` (value equality) vs `==` (numeric-tower equivalence)

**Status**: Accepted (Devil's-advocate fork landed 2026-05-29)
**Date**: 2026-05-29
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: correctness-bug, equality, F-005, F-009, D-136, numeric-category

## Context

`=` in cw v1 was a **correctness bug**: registered in
`lang/primitive/math.zig` as `equals` → `pairwise("=", … pEQ)`
(numeric pairwise via `ensureNumeric`), so `(= :a :a)` / `(= "a" "a")`
/ `(= [1 2] [1 2])` / `(= true true)` / `(= nil nil)` / `(= 1 nil)`
all raised `type_error` instead of returning a boolean. JVM `=`
(`clojure.lang.Util.equiv`) is universal value equality and never
raises. No `==` existed. Surfaced 2026-05-29 writing `dedupe` (D-134);
this bug blocks the whole coverage floor (D-133) — dedupe / distinct /
frequencies / group-by / set-membership on non-numbers all need it.

Survey: `private/notes/phase14-D136-equality-survey.md`. Findings:
bit-pattern equality is correct for nil/bool/int/char/builtin_fn +
interned keyword/symbol; cw v1 has NO structural equality (greenfield);
`hash.zig` is Murmur3 only (the map-comment pointer to "deep = via
hash.zig" is misdirected). cw v0's `=` was **category-blind**
(`(= 1 1.0)`→true) = non-JVM; cw v1 diverges to JVM's category gate.

## Decision

### D1: `=` = universal value equality; `==` = numeric-tower equivalence

- New neutral `src/runtime/equal.zig` (F-009) exposes
  `valueEqual(rt, a, b) bool`. The `=` primitive folds it pairwise.
- `==` is added as the numeric primitive = the current `=` body
  renamed (`pairwise("==", … pEQ)`); it keeps the numeric-only
  `type_error` for non-numbers (JVM `==` is numeric-only too).
- `valueEqual` **never raises** — different/unhandled tags → false.

### D2: `valueEqual` dispatch (Alt 2, finished-form-clean)

1. **Identity fast path**: `@intFromEnum(a) == @intFromEnum(b)` → true.
   Covers nil / bool / int / char / builtin_fn / interned keyword /
   interned symbol / pointer-identical heap.
2. **Numeric arm** (both numeric), category-gated per **F-005**:
   category(int, big_int) = `.integer`; float = `.floating`;
   ratio = `.ratio`; big_decimal = `.decimal`. **Different category →
   false** (`(= 1 1.0)`→false). Within category: int i48 eq,
   `big_int` `Managed.eql`, float `==`, ratio reduced num/den eq,
   big_decimal `compareTo == 0`. **All five constructible categories
   are covered now** — leaving big_int/ratio/decimal on the
   bit-pattern fallthrough would make `(= 1N 1N)` (distinct heap allocs)
   → false, a silent wrong answer (permanent-no-op).
3. **Sequential arm** (both sequential): element-wise via a unified
   tagged first/rest cursor, so `(= '(1 2) [1 2])`→true (JVM-correct).
   Maps/sets are NOT sequential (`(= #{1} [1])`→false).
   **Scope (implementation re-lay, Step 0.6)**: `valueEqual` lives at
   Zone 0 (`runtime/equal.zig`) taking `rt` (signature
   `valueEqual(rt, a, b) anyerror!bool` — real errors like OOM /
   chunked-rest propagate; type mismatches return false). The general
   seq-walk machinery (`sequence.zig`) is Layer 2 and `lazy_seq`
   realization needs `env`, so the Zone-0 cursor covers the tags with
   Zone-0 first/rest: **vector (nth/count), list, cons, chunked_cons**.
   `range` / `array_seq` / `string_seq` / `lazy_seq` sequential
   equality is **deferred** (env / lazy-realization dependency — these
   are also barely constructible at Phase 14: range/repeat/iterate are
   unimplemented per D-134). Tracked as a D-136 follow-up note.
4. **Same-tag content arms**: string (byte eq); array_map/hash_map
   (count + per-key `get` + recurse, key lookup rides existing
   bit-pattern `keyEq` — see D3); hash_set (count + `contains`);
   keyword/symbol (name eq — backstop for any non-interned case).
5. **Different tag** (after the cross-type arms) → false.

### D3: scope boundary — keyEq widening deferred to D-092 (a real dependency)

The map ArrayMap `keyEq` stays bit-pattern this cycle. Widening it to
`valueEqual` requires a **validated structural `valueHash`** in
`hash.zig` (hash/eq consistency: equal values → equal hashes), which
does not exist. That is a genuine correctness dependency, **not** a
cycle-budget defer — tracked as **D-092**. `=` as a standalone
predicate is fully correct over structural collections without it
(only collection-keyed map/set *lookup* is affected, not `=`).

Cross-category `==` (`(== 1N 1.0)`) is also deferred — it needs the
numeric-tower combine ladder (D-014a family), a real dependency. `=`
never needs it (the category gate makes cross-category `=`→false).

### D4: recursion

Persistent immutable structures cannot cycle, so `valueEqual`
recursion terminates. No depth guard for v0.1.0 (only pathological
deep nesting risks stack; not a daily-driver concern). Known limit,
revisit if a crash surfaces.

## Alternatives considered

Devil's-advocate fork (general-purpose, fresh context, 2026-05-29,
F-005/F-009/F-002 envelope) output verbatim:

**Envelope reminder.** F-005 fixes the numeric-category *direction* (`(= 1 1.0)`→false, `==` widens) — not open. F-009 fixes the *location* (`runtime/equal.zig`, thin `=`/`==` wrappers) — not open. The open axes: (i) sequential cross-type now vs defer, (ii) numeric-category scope, (iii) `==` now vs later, (iv) keyEq widening in/out, (v) recursion depth guard. No alternative requires an F-NNN amendment.

### Alt 1 — Smallest-diff

(a) `valueEqual` with identity fast-path → numeric arm covering **int+float only** (big_int/ratio/big_decimal fall to same-tag fallthrough) → same-tag by-content arms (string byte eq; vector count+nth; list/cons same-tag-only walk, NO cross-type; map count+get; set contains) → different-tag→false. `==` = current `=` body renamed. Out: sequential cross-type, big/ratio/decimal same-category, keyEq (D-092), depth guard.

(b) Better: least surface; lands the P0 fix touching only math.zig + new equal.zig; every deferred axis has a D-row.

(c) Breaks: `(= '(1 2) [1 2])`→false diverges from JVM (F-005 surface mismatch; into/concat/distinct over mixed seq+vec mis-dedupe). `(= 1N 1N)` on distinct big_int heap allocs → false — a silent wrong answer (permanent-no-op row 4) with no marker. That last is the dangerous risk.

### Alt 2 — Finished-form-clean (recommended)

(a) Same file/signature. Numeric arm covers **all five categories** (integer{int,big_int}/floating/ratio/decimal) with category gate (F-005), within-category via int eq / `big_int Managed.eql` (big_int.zig:238) / float == / ratio num·den / big_decimal compareTo. **Sequential cross-type arm**: `isSequential` = list/cons/chunked_cons/vector/range/array_seq; both sequential → element-wise unified first/rest-or-nth cursor (`(= '(1 2) [1 2])`→true). Same-tag content arms (string/kw/sym/map/set) as Alt 1. `==` added now. keyEq widening OUT (D-092). No depth guard (bounded-nesting note).

(b) Better: matches JVM `=` on every Phase-14-constructible value in one cycle; dedupe/distinct/set-membership/frequencies/group-by behave correctly over mixed collections immediately; no silent wrong answers (every constructible numeric category compared correctly). The sequential cursor is the natural shape — a later list==vector cycle would rewrite the list/vector arms anyway, so doing it now *shrinks* total work (permanent_noop_forbidden: skeleton must shrink the rewrite).

(c) Breaks: larger cycle (unified cursor + 5-category ladder = more code + test surface); big_decimal/ratio same-category compare has scale/reduction subtleties (mitigated: ratios stored reduced, big_decimal via compareTo==0); the sequential cursor MUST treat maps/sets as non-sequential (`(= #{1} [1])`→false) — covered by a negative test.

### Alt 3 — Wildcard

(a) Land `valueEqual` PLUS structural `valueHash` in `equal.zig`, then widen map `keyEq` to `valueEqual` + wire structural hash into map key lookup — fold D-092 into this cycle. Numeric all-category + sequential as Alt 2. `==` now.

(b) Better: complete Clojure equality story in one shot — `(get {[1] :x} [1])`→`:x`, collection-keyed maps/sets work; eliminates the D-092 follow-up.

(c) Breaks: a genuine **dependency-bearing scope jump, not cycle-budget**: keyEq→valueEqual is only correct with a structural `valueHash` satisfying the hash/eq invariant for string/collection keys + a re-audit of the map's internal probing. `hash.zig` has no structural Value composition today; building+validating `valueHash` (collision behavior, ordered vs unordered for vector vs set/map) is its own correctness surface. Folding couples two independently-testable fixes, enlarging blast radius. **Distinct from F-002**: F-002 forbids deferring on *cycle size*, not respecting a real *correctness dependency boundary*; the hash/eq-consistency boundary is legitimate, so deferring keyEq (D-092) is NOT a Cycle-budget defer smell.

### Recommendation (non-binding) — Alt 2, anchored to F-002 + F-005

1. **Sequential cross-type — INCLUDE now.** JVM-observable (F-005) + the D-134 dedupe/distinct unblock depends on it for mixed seq+vec; list+vector arms both need a first/rest-or-nth walk anyway, so unifying now is *smaller total* than same-tag-now + cross-type-rewrite-later. Deferring = Cycle-budget defer smell (no dependency block). Overrides survey §8's tentative defer.
2. **Numeric — ALL constructible categories now.** big_int/ratio/big_decimal are constructible at Phase 14 (`big_int.eql` exists); leaving them on bit-pattern → `(= 1N 1N)`→false silent lie (worse than a raise). Category gate is free (F-005). Cross-category `==` stays deferred (combine-ladder dependency, D-014a) — `=` never needs it.
3. **`==` — ADD now** (current `=` body renamed + one ENTRIES row; zero new logic).
4. **keyEq widening — OUT (D-092)**: the one *legitimate* defer — needs validated structural `valueHash` (hash/eq consistency), a separable correctness surface, not a budget punt. `=` is fully correct without it.
5. **Recursion depth — TRUST bounded** for v0.1.0 (immutable → terminates; one-line note, not a marker).

Why Alt 2 over Alt 1: Alt 1's deferred arms are held back only by diff size (F-002 rejects that) and it ships the `(= 1N 1N)`→false lie. Why over Alt 3: Alt 3 crosses the real D-092 hash/eq dependency without a finished-form *correctness* gain to `=` itself.

## Selection rationale

Alt 2. It is the shape where every Phase-14-observable JVM `=` behavior
is correct (numeric category gate per F-005, sequential cross-type,
structural collections) and nothing is deferred except what a real
dependency forces (keyEq/hash → D-092; cross-category `==` → combine
ladder). Alt 1 ships a silent `(= 1N 1N)`→false lie + diverges on
sequential; Alt 3 couples the D-092 hash/eq surface without a
correctness gain to `=`.

## Consequences

- New `src/runtime/equal.zig` (`valueEqual` + numeric-category helper).
- `lang/primitive/math.zig`: `=` rewired to `valueEqual`; `==` added as
  the numeric primitive (former `=` body). Both Tier A by clojure.core
  aggregate (no per-var compat_tiers entry).
- Unblocks D-134 dedupe/distinct/frequencies/group-by (next cluster).
- D-092 (keyEq widening + structural valueHash) referenced as the
  follow-up for collection-keyed map/set lookup; cross-category `==`
  deferred to the numeric-combine ladder (D-014a family).
- Existing number-vs-number `=` tests keep passing.

## Affected files

- `src/runtime/equal.zig` (new) · `src/lang/primitive/math.zig`
  (= rewire + == add) · `test/e2e/phase14_equality.sh` (new) ·
  `src/main.zig` test aggregator (if equal.zig needs reachability) ·
  `.dev/debt.md` (D-136 discharge, D-092 reference).

## Revision history

- 2026-05-29 issued + accepted with Devil's-advocate fork
  (general-purpose, fresh context, F-005/F-009/F-002 envelope, 3
  alternatives verbatim, Alt 2 selected). Fixes the numeric-only `=`
  bug (D-136); splits `=` (universal, Util.equiv) from `==` (numeric,
  Numbers.equiv) per JVM; category-gated numeric `=` per F-005
  (diverging from cw v0's category-blind `=`).
