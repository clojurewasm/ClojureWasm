# ADR-0076 — clj-parity root-cause campaign + accepted-divergence framework

**Status**: Proposed → Accepted (2026-06-02, user-directed)

## Context

The post-M F-010 quality loop runs a differential sweep (cljw vs the real
`clj` oracle, F-011). A periodic audit surfaced the user's concern verbatim
(2026-06-02):

> 「たまにしか監査しないけど、そういう細かい不一致が、利用されるときの
> 不信感につながりそうだと思ってます。…まず、ねじこみで、それらを根本的に
> 解決する調査と取り組みをつぶし、また、そういう妥協や先送りを、A系は解消。
> Bは…妥当な差異なので、しっかり許容した、と記録…ようにルール化や自動防御
> したい。次のクリアセッションからさっそく対処がねじ込まれるよう、配線や参照
> チェーンを準備した…」

The divergences split two ways:

- **A — real gaps** that visibly differ from clj where clj succeeds (a user
  could hit them and lose trust). Several were *deferred* as "structural" or
  "user-gated" — the user is now lifting that deferral and directing
  root-cause resolution (F-002: finished-form wins; big surgery is the
  default, not the exception).
- **B — intentional divergences** that are correct for cljw's design (no-JVM,
  numeric-tower, unordered-collection semantics). These must be *recorded as
  designed* so they neither erode trust nor get accidentally "fixed".

## Decision

Two faces of one discipline, in one ADR (DA Alt 2 + Alt 3's corpus-pin):

### (1) Accepted-divergence framework (the B half)

- **SSOT** `.dev/accepted_divergences.yaml` — AD-001…AD-007, each with
  `summary` / `example` / `why` / **`derives_from`** (an F-NNN or ADR) /
  **`pin`** (a corpus/e2e test locking cljw's divergent value).
- **Rule** `.claude/rules/accepted_divergences.md` — every clj DIFF is
  classified **bug→fix** OR **accepted→AD-NNN with a `derives_from`**, never
  left floating (the Defer-to-amnesia smell). Auto-loads on runtime/harness
  edits.
- **Gate** `scripts/check_accepted_divergences.sh --gate` (in
  `test/run_all.sh`) — enforces `derives_from` present + `pin` paths exist +
  COVERAGE.md points at the SSOT. The **pin reuses the existing
  `check_corpus_regression.sh`** (a corpus line carrying cljw's expected
  value) rather than a second regression runner (F-011, anti-D-177): if a
  future change flips an accepted divergence, the corpus regression fails →
  a conscious decision is forced.

### (2) clj-parity root-cause campaign §9.2.P (the A half)

A ROADMAP campaign overlay (mirrors §9.2.S perf campaign; does not renumber
§9.2.R), anchored as a standing **`quality-loop floor: clj-parity`** debt
Barrier so it is repeatable and cannot rot half-done (F-010). The seven A
items, with the DA's loop-resolvable-vs-user-owned split made HONEST (no
false "root-cause" promise on items that need a user F-NNN amendment):

| Unit      | Debt  | Gap                                                         | あるべき論 (finished form)                                                                                                    | Owner                  |
|-----------|-------|-------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|------------------------|
| C1 (lead) | D-164 | empty `()`/seq collapses to `nil`; `(seq? '())`→false      | interned distinct empty value inside existing `.list`/seq tags (no new slot); uniform across every seq fn                     | **loop**               |
| C2        | D-205 | BigDecimal map-key `(get {1.5M :v} 1.5M)`→nil              | numeric arm in rt-free `keyEqValue` + scale-normalized hash, or canonical-scale at construction                               | **loop**               |
| C3        | D-207 | `.toString`/`.equals`/`.hashCode`/`.getClass` unimplemented | dispatch-level Object fallback → `str`/`=`/`hash`/`class` (F-009 wrapper)                                                    | **loop**               |
| C4        | D-209 | `map-entry?` + distinct MapEntry                            | activate the **reserved** Group-A `.map_entry` slot (consuming a reservation ≠ amending F-004)                               | **loop**               |
| C5        | D-198 | `(Exception. "x")` host-class ctors                         | D-048 host-class machinery (dependency-ordered)                                                                               | **loop** (after D-048) |
| C6        | D-200 | `#inst`/Date                                                | ship the **no-slot** cljw-native `typed_instance` Date (loop-resolvable); a dedicated `.date` slot is a **user F-004** option | **loop** + user (slot) |
| C7        | D-165 | long ∈ (2^47, 2^63] prints as BigInt `…N`                 | full-Long needs a wider NaN-box payload (F-004) or heap-boxed-Long-without-`N` (F-005) — **both user-owned LAW**             | **user F-NNN**         |

**Honest scope**: C1–C5 are loop-resolvable now. C6 ships the no-slot Date
autonomously; the dedicated-slot variant + C7 require a **user F-004/F-005
amendment** and are surfaced as decision points, NOT auto-decided (treating
F-004/F-005 as informational would be the Smallest-diff-bias smell on
user-LAW). The campaign records C7 (and the C6 slot variant) as a debt row
flagged `user-owned F-NNN decision`, not as an accepted divergence and not
as a false root-cause promise.

**Order**: C1 (highest leverage — one fix, every seq fn) → C2 → C3 → C4 →
C6(no-slot) → C5(after D-048). C7 + C6-slot await the user's F-NNN call.

## Consequences

- The next clean session resumes onto C1 (handover Resume contract + the
  `quality-loop floor: clj-parity` Barrier wire it as the first work).
- Each unit is its own commit (revert-friendly), F-002/F-011-held, gated,
  and leaves a corpus line behind (anti-D-177 mechanical re-check).
- B divergences are locked + justified; a future sweep sees AD-001…007 as
  ACCEPT, not noise, and cannot silently flip them.
- D-164/D-165 move from the "discharged-structural-defer" limbo back to
  active campaign units with honest ownership.

## Affected files

- new: `.dev/accepted_divergences.yaml`, `.claude/rules/accepted_divergences.md`,
  `scripts/check_accepted_divergences.sh`
- edit: `test/run_all.sh` (gate), `test/diff/clj_corpus/COVERAGE.md` (point at
  SSOT), `.claude/rules/clj_diff_sweep.md` (cross-ref), `.dev/ROADMAP.md`
  (§9.2.P), `.dev/debt.yaml` (D-164/165/198/200/205/207/209 statuses +
  `quality-loop floor: clj-parity` anchor), `.dev/handover.md` (Resume
  contract).

## Alternatives considered

(Devil's-advocate subagent, fresh context, per CLAUDE.md depth-≥2 mandate.
Verbatim; full copy in `private/notes/da-adr-0076.md`.)

### Alt 1 — Smallest-diff: two ADRs, ship only the framework now; campaign is a placeholder

ADR-0076 records ONLY framework (a); a separate ADR-0077 opens §9.2.P as an
un-accepted placeholder, each A-item un-defer being its own later ADR.

**Better:** clean separation of a permanent mechanism (framework) from a
transient schedule (campaign); lets `check_accepted_divergences.sh` go green
immediately with AD-001..007 without waiting on hard structural work; each
A-item gets its own fresh-context DA fork when it actually fires.

**Breaks/risks:** the campaign loses its teeth — a bare placeholder with no
acceptance is exactly the decision-deferral the user is directing the loop to
stop, i.e. the **Cycle-budget defer smell** in process-hygiene costume, and
re-opens the drip-feed (Micro-coverage-grind) the clj_diff_sweep "big-bang"
Discipline 2 forbids. The classify-rule is half a loop without the campaign
saying which deferred DIFFs are bugs vs accepted, leaving the A-items in the
floating-DIFF state the rule bans. **Not recommended on F-002 grounds.**

### Alt 2 — Finished-form-clean: one ADR; campaign as a standing F-010 `quality-loop floor: clj-parity`; route each A-item to its true owner

One ADR (framework + campaign are two faces of one discipline). Campaign is a
debt-driven standing floor (repeatable per F-010, cannot rot half-done)
rather than a one-shot phase with seven pre-decided directions. The SSOT
carries both `accepted` and `bug-deferred` statuses (so "never floating" is
gate-checkable). The pin is generalised to a **corpus line carrying cljw's
expected value, enforced by the already-existing `check_corpus_regression.sh`**
(no second regression runner — F-011). Each A-item routes to its real
structural owner.

**Better:** resolves the F-003 tension head-on instead of papering over it —
the user lifting the deferral un-defers the *work*, but the *representation
choice* for the two F-004/F-005-touching items still routes to the user as
F-NNN owner because the loop literally cannot pick a clean shape there without
amending user-LAW. Reuses the corpus regression mechanism as the pin (F-011,
anti-D-177). Keeps the campaign repeatable so it cannot rot.

**Breaks/risks:** larger up-front mechanism (not an F-NNN cost — F-002
accepts large finished-form diffs); surfaces user-owned amendment touchpoints
for D-165 and the D-200 dedicated-tag (the loop does NOT halt — it ships the
loop-resolvable shapes and records the rest as user-owned). **Recommended per
F-002.** Critical correction over the draft: D-165 and a dedicated #inst slot
cannot be loop-resolved without a user F-004/F-005 amendment, so the campaign
must classify them as user-owned rather than promise root-cause, or it ships
a false-positive-discharge lie.

### Alt 3 — Wildcard: no separate SSOT; fold both halves onto the corpus + debt machinery, let the oracle be the gate

No `accepted_divergences.yaml` / `check_accepted_divergences.sh`. An accepted
divergence is a corpus line with an inline `# AD: <why> [derives: F-NNN]`
annotation recording cljw's value; `check_corpus_regression.sh` auto-pins it;
a grep generates the catalog. Campaign rides debt.yaml `quality_floor:
clj-parity` + the existing F-010 floor.

**Better:** strongest F-011 reading — zero new SSOT, zero new gate; the pin is
intrinsically the regression test; no parallel scheduling structure.

**Breaks/risks:** loses structured `derives_from`/`why` enforcement (a comment
convention is far weaker than a gate checking "every AD has a derives_from");
conflates a regression *fixture* with a design *record* (burying AD rationale
in test comments, making COVERAGE.md point at scattered files); property-shaped
divergences (set print-order, error-Kind) have no natural single-expression
corpus line. **Best as a contributor to Alt 2 (corpus line as the pin), not
the whole shape.**

### Decision vs the alternatives

**Alt 2 chosen, folding in Alt 3's corpus-line-as-pin** (the `pin` field
points at the corpus/e2e that locks the value; the gate checks existence, the
existing `check_corpus_regression.sh` does the re-run — no second runner).
Alt 1 rejected: it re-introduces the deferral the user is directing the loop
to eliminate (F-002). The DA's leading flag is honoured: **C7 (D-165) and the
C6 dedicated-`.date`-slot have no finished-form-clean shape inside the current
F-004/F-005 envelope — each needs a user amendment; the campaign records them
as user-owned, ships the 5 loop-resolvable items + the no-slot Date, and does
not halt.**

## Revision history

- 2026-06-02 created (Accepted): user-directed. Framework + campaign landed
  as wiring this session; C1… execution begins next clean session.
- 2026-06-02 amendment 1 (am1): the two "user-owned F-NNN" flags resolved by
  user decision in chat, so **all 7 units are now loop-resolvable**:
  - **C6 #inst** — user confirmed the **no-slot `typed_instance` Date** (β);
    no dedicated `.date` slot. `(class …)`→`Date` is consistent with AD-003
    (simple class names). C6 is fully loop.
  - **C7 D-165 (long range)** — user decided **heap-boxed Long, representation
    B2** (a `Long-origin/fits-i64` flag on the heap-integer struct; **NO new
    NaN-box slot, F-004 layout UNCHANGED**). This is NOT an F-NNN amendment:
    F-005's stated surface already wants Long-to-full-i64, and the internal
    representation is F-005's "Zig-native" domain (loop's call). NaN-box
    i64-inline was confirmed fundamentally impossible (cw v0 also i48; an
    8-byte Value cannot hold tag + i64). Heap-box mirrors the JVM (`Numbers.num(long)`→`Long.valueOf`).
  - **Long overflow past i64** — user ratified **auto-promote** ("A は Promote
    推奨どおり"): cljw `+`/`*` promote to BigInt on i64 overflow (per F-005's
    existing promote-clause — **F-005 NOT amended**). clj's checked-`+`/`*`
    THROW (`Math.addExact`) is recorded as the accepted divergence **AD-008**.
    The promoting `+'`/`*'` family is unimplemented + F-005's `+'`-clause is
    clj-inverted → deferred to **D-211**.
  - Net: no user-LAW amendment was needed (F-004 + F-005 unchanged); the
    campaign is now 7 loop-resolvable units. The C7-as-user-owned text in the
    Decision table above is superseded by this am1.
