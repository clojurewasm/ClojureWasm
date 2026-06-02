# Tech-debt consolidation audit — 2026-05-31

> **Purpose.** A one-time cross-project sweep (5 parallel discovery
> agents + main-agent verification) for work that *should* follow the
> finished-form / behavioural-equivalence ideal but has been **silently
> dropped or under-recorded** — i.e. deferrals with no real resolution
> trigger. The goal is to **wire every live item into the debt /
> dependency trigger system** so the autonomous loop drains it, instead
> of letting it rot in a code comment or the non-authoritative
> `private/` ledger.
>
> **This doc is the human-readable index + diagnosis.** The LIVE
> triggers are the `.dev/debt.yaml` rows it references (Step 0.5 sweep is
> what fires them). Raw per-lens findings:
> `private/notes/audit-lens{A..E}-*.md` (gitignored scratch).

## How an item actually gets resolved (the trigger mechanism)

1. `.dev/debt.yaml` row with a **`Barrier`** (trigger predicate).
2. **Step 0.5 Debt sweep** (CLAUDE.md): every resume re-evaluates
   Barriers of rows > 14 days old; **at a Phase entry** reads rows whose
   Status names the entering Phase.
3. `feature_deps.yaml` + `PROVISIONAL:` marker triad for in-code
   provisional behaviour (`scripts/check_provisional_sync.sh`).
4. `private/` (ledger, per-task notes) is **NOT load-bearing** —
   anything recorded only there has **no** trigger.

## The systemic finding: why items go silent (5 failure modes)

The audit found ~50 candidate items. They cluster into 5 recurring
failure modes — each is a way the trigger system leaks:

| Mode   | Name                                 | What it is                                                                                                                                      | Count |
|--------|--------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|-------|
| **M1** | Orphan deferral                      | A real should-do recorded only in a code comment or the `private/` ledger — no `D-NNN`, no `feature_deps` key. Never swept.                    | ~12   |
| **M2** | Dead-Phase barrier                   | A `debt.yaml` row whose Barrier names a Phase (5/7/11/…) that **already closed**. Step 0.5 will never re-read it.                              | ~12   |
| **M3** | Weak / self-referential barrier      | Barrier is vague or circular ("when the X cycle opens" with nothing scheduling X). Swept, re-read, re-deferred forever.                         | ~6    |
| **M4** | Rationalized "acceptable" divergence | An observable input→output gap vs `clj` waved through on **effort** grounds (F-011 forbids effort as a reason).                                | 2     |
| **M5** | Sync rot                             | Discharged rows never moved; stale `PROVISIONAL` markers / comments citing already-discharged debts; phantom `D-NEW` IDs that were never filed. | ~25   |

### The root structural cause (the real テコ入れ target)

debt Barriers were authored assuming **sequential one-time Phase
entries**. But the project finished Phases 1–14 and is now in the
**post-M F-010 quality-elevation loop** — a *repeatable* operating mode
(clj-differential sweep + corpus loading), **not a Phase**. So:

- Rows bound to **closed** Phases 5–11 are permanently stranded (M2).
- The quality loop has **no debt-trigger hook** — it sweeps categories
  ad hoc, so correctness items are not systematically drained.

**Structural fix → a "Quality-loop coverage floor" trigger class**
(see next section). Re-home stranded correctness/coverage rows onto it;
give the F-010 loop a step that drains it by category each pass.

## The structural fix: Quality-loop coverage floor

1. **New Barrier vocabulary** `quality-loop floor: <category>` — e.g.
   `seq-fn` / `numeric-tower` / `JSON-parity` / `string-seq` /
   `dual-backend-parity` / `corpus`. A row with this Barrier is a
   standing correctness/coverage debt the F-010 loop must drain.
2. **Loop wiring** (CLAUDE.md + handover): the quality-elevation loop's
   operating procedure gains an explicit step — *"before picking the
   next sweep target, read all `quality-loop floor` rows; drain by
   category, highest value first."* This makes the loop **debt-driven**,
   not ad-hoc, so nothing in the floor is forgotten.
3. **Re-anchor** the M2/M3 correctness rows onto the matching floor
   category (one-time Phase barriers → standing floor).
4. **Mechanical backstop** — `scripts/check_debt_id_refs.sh` (new): every
   `D-NNN` cited in `src/**` / docs must exist in `debt.yaml` (kills
   phantom `D-NEW`); and a count of open `quality-loop floor` rows is
   printed at gate time so the backlog is visible. Wire into
   `test/run_all.sh` (informational first, gate later).

## Action list

Status legend: **VERIFIED** (main-agent re-probed vs `clj`) ·
**CODE-READ** (confirmed by reading source, reliable) · **VERIFY**
(agent-claimed, not yet re-probed — confirm before fixing) ·
**FACTUAL** (about debt/ADR structure, not behaviour).

### A. New rows to file — verified / code-read correctness & coverage gaps (M1)

| New ID    | Item                                                                                                                                                                                                                                                                                                                                                                          | Status    | Value | Proposed Barrier                                                                                                           |
|-----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------|-------|----------------------------------------------------------------------------------------------------------------------------|
| **D-168** | `(range n)` / `(range a b)` return an **eager vector**, not a seq: `(seq? (range 3))`→cljw false/clj true; `(pr-str (range 3))`→`[0 1 2]`/`(0 1 2)`; `(conj (range 3) 99)` diverges (append vs prepend). **Inconsistent with cljw's own 3-arg `range`, which already returns a lazy seq.** Not a rule — a leftover of the vector→seq cluster fix.                         | VERIFIED  | HIGH  | `quality-loop floor: seq-fn` (align 1/2-arg with the correct 3-arg form; chunked LongRange is the finished form per F-004) |
| **D-169** | `(quot 10N 3N)` / `rem` / `mod` **throw** on BigInt (`expected integer, got big_int`); clj → `3N`. F-005 numeric-tower gap.                                                                                                                                                                                                                                                  | VERIFIED  | MED   | `quality-loop floor: numeric-tower`                                                                                        |
| **D-170** | `(int 5N)` / `(int 7/2)` **throw** (`expected number, got big_int`/`ratio`); clj → `5`/`3`. The `int`/`long`/`unchecked-*` coercion arms don't cover the full tower.                                                                                                                                                                                                         | VERIFIED  | MED   | `quality-loop floor: numeric-tower`                                                                                        |
| **D-171** | `json.zig:134` writes floats with Zig `{d}` — the **pre-D-166 layout** (no scientific notation). The D-166 fix landed in `print.zig::printFloat` but did NOT reach the JSON writer → divergence vs `clojure.data.json`. Fix: call the now-`pub printFloat`. Same file raises `feature_not_supported` for i48-overflow / arbitrary-precision JSON numbers with no close-out. | CODE-READ | MED   | `quality-loop floor: JSON-parity`                                                                                          |
| **D-172** | `Math/addExact` / `multiplyExact` / `subtractExact` / `negateExact` / `incrementExact` / `decrementExact` / `toIntExact` — unimplemented (overflow→`ArithmeticException`, a distinct mechanism from `floorDiv`/`floorMod`). Ledger-only today.                                                                                                                              | VERIFY    | MED   | `quality-loop floor: Math-statics`                                                                                         |
| **D-173** | Integer/Long `lowestOneBit` / `reverseBytes` / `rotateLeft` / `rotateRight` / `signum` — same `BitOp` pattern (rotate is arity-2). Low call-frequency from Clojure. Ledger-only.                                                                                                                                                                                             | VERIFY    | LOW   | `quality-loop floor: Java-statics (low-priority tail)`                                                                     |
| **D-174** | `(rest "abc")` / `(next s)` return a **String**, not a char-seq: `(string? (rest "abc"))`→cljw true/clj false. The ledger labels this "low priority" citing O(n²) — i.e. **effort-rationalized (M4)**; a lazy char-seq is O(n).                                                                                                                                            | VERIFIED  | MED   | `quality-loop floor: string-seq`                                                                                           |

### B. Needs investigation before filing (suspected real, higher risk)

| Ref        | Item                                                                                                                                                                                                                                                                                                        | Status               | Value        |
|------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------|--------------|
| **D-175?** | **Namespace registry `user`-duplicate + phantom `example` ns** — a suspected structural defect surfaced in `private/notes/allns-state.md`; `all-ns` work was discarded uncommitted, blocked on it. Zero trigger today.                                                                                     | VERIFY (investigate) | HIGH if real |
| **D-176?** | **VM-DEFER reactivation** (`compiler.zig:346`/`:516`) — the VM backend raises `error.NotImplemented` for catch-type-keyword and ns-filter/libspec; cites Discharged D-014b/D-098 but the real prereq (D-100 constants pool) **landed 2026-05-29**. A dual-backend parity gap (F-011) with no live Barrier. | VERIFY               | HIGH         |
| **D-177?** | Transducer single-arity (`map`/`filter`/`take`/… 1-arg) + N-ary `comp`/`complement` — comments cite phantom `D-NEW-2`; real prereq (multi-arity, **D-070**) is Discharged, so this is doable now.                                                                                                         | VERIFY               | MED          |
| —         | `valueToForm` fidelity (char / bignum / hash_map) — note says "debt 行未起票".                                                                                                                                                                                                                             | VERIFY               | LOW-MED      |
| —         | `ns-interns` fidelity; Namespace `pr-str` form; `map` N-coll / `list*` variadic (partial D-134 only).                                                                                                                                                                                                       | VERIFY               | LOW-MED      |

### C. Re-anchor dead-Phase barriers (M2) — existing rows, Barrier rewrite only

Phases 1–14 are closed; the next real entry is **Phase 15**. Re-anchor
each to **Phase 15 entry** or a `quality-loop floor` category (whichever
fires first), per Lens C/D:

- **D-016** (Phase-5 mark-sweep bench — results exist, never re-read),
  **D-019** (Phase 5/7/11/14 boundary audits — all closed),
  **D-023 / D-024** (Phase-4/5 §9.6 anchors, closed),
  **D-041 / D-042** (Status literally "Phase 5 passed, cleanups
  un-executed"), **D-043** (Phase-7 entry, closed).
- **Phase-7.x semantic cluster** — **D-087** (deftype Name unbound),
  **D-090** (fn-body `recur`), **D-091** (`defn` docstring), D-086,
  D-088: real gaps bound to closed Phase 7, demoted to "opportunistic"
  at closed Phase 10 → invisible. Re-bind to `quality-loop floor`
  (these are coverage-floor correctness items).

### D. Rewrite weak / self-referential barriers (M3)

**D-012, D-015, D-022, D-038-ext, D-044, D-047-ext** — replace
"when the X cycle opens" / ownerless predicates with a detectable
trigger (Phase 15 entry, a file-touch event, or a `quality-loop floor`
category). Full per-row proposals in `audit-lensC-barrier-quality.md`.

### E. Housekeeping / sync rot (M5)

- **Move ~22 inline-DISCHARGED rows** out of the `## Active` table into
  `## Discharged` (Lens C). **Fix the D-018 duplicate** (in both
  sections). **Flip D-064** (substance discharged by D-100(e)).
- **Stale `PROVISIONAL` / comments** (trigger already fired): `rename-keys`
  (`set.clj:73`, D-076 discharged — restore vector destructure + flip
  yaml to landed); `bootstrap.zig` "cosmetic gap" comment lags discharged
  D-058.
- **Stale test comments** (false "acceptable divergence" records):
  `phase14_core_cluster.sh` (concat/mapcat now return seqs);
  `phase6_clojure_set_group_c.sh` (project/rename now preserve metadata).
- **Phantom debt IDs** `D-NEW` / `D-NEW-2` / `D-NEW-A` — **DONE 2026-06-01**:
  `D-NEW-2` (6 sites: core.clj ×3, higher_order.zig, transducer_unlock_a3.sh ×2)
  → **D-177** filed (transducer single-arity + N-ary comp; prereq D-070 is
  Discharged, so doable). `D-NEW` (macro_transforms.zig:1573, defmulti re-eval
  clobber) → **D-184** filed. `D-NEW-A` was in `.dev/decisions/0035` (immutable
  ADR narration) — handled by excluding `.dev/decisions/` from the phantom scan.
  Also: **D-162** (eval/ADR-0058, discharged but never row-recorded → flagged
  UNDEFINED) got a Discharged row. `check_debt_id_refs.sh` is now **gating**
  (`--gate` in run_all.sh).

### F. Structural-deferred — keep deferred, verify trigger live, annotate (F-003)

- **D-164** (empty-seq ≡ nil) and **D-165** (i48→i64 long prints `N`) are
  correctly structural (value-model / NaN-box 2nd-gen owner), BUT Lens E
  flags their Barriers **under-state frequency**: corpus loading hits both
  **immediately** (empty filter/map results everywhere; nanos/IDs exceed
  2^47). Annotate as **front-of-quality-loop** priorities; fix-path
  unchanged.
- **D-006 / D-036 / D-037 / D-039** (zwasm v2 integration) — bound to
  Phase 15/16+, **alive** (loop reaches them), just distant. Leave.
- **D-160, D-163, D-057** — legitimate structural/perf/Unicode deferrals
  with live triggers. Leave.

### G. False positives found during audit — do NOT file

- **`pos-int?` / `neg-int?` / `nat-int?` return false for BigInt** (Lens A
  flagged as a bug) — **NOT a bug.** Re-probed: `clj` agrees
  (`(pos-int? 5N)`→false, `(int? 5N)`→false). Clojure's `int?` is
  documented "fixed precision integer" and **excludes BigInt by design**;
  cljw matches. *Lesson: agent correctness claims MUST be re-probed vs the
  `clj` oracle before filing — this one would have been a wrong "fix".*
- **Astral-plane `count`** (ADR-0014) — genuine permanent rule (UTF-8
  code-point semantics); only the ADR prose "well-behaved code unaffected"
  overclaims for the BMP. Doc nit, not debt.

## Recurrence prevention (so this doesn't re-accrue)

1. **`scripts/check_debt_id_refs.sh`** — every `D-NNN` cited in `src/**` +
   tracked docs (excluding `.dev/decisions/` ADRs = immutable narration) must
   exist in `debt.yaml`. Kills phantom `D-NEW`/typo IDs. **Now GATING** as of
   2026-06-01 (`--gate` in `run_all.sh`) — the initial phantom backlog
   (`D-NEW-2`/`D-NEW`/`D-NEW-A` + undefined `D-162`) was drained first, then the
   check was flipped from informational to hard-fail so phantoms cannot
   re-accrue. (M5)
2. **Quality-loop floor backlog count** printed at gate time — the open
   `quality-loop floor:` row count is surfaced so the F-010 loop can't
   ignore the floor. (M1/M2)
3. **CLAUDE.md quality-loop step** — "drain `quality-loop floor` debt rows
   by category before choosing a fresh sweep target." Makes the loop
   debt-driven. (root cause)
4. **Audit cadence** — re-run this 5-lens sweep at each Phase boundary
   (fold into `audit_scaffolding`), so M1/M5 are caught within one Phase,
   not one year.

## Execution plan (this consolidation's own close-out)

1. **[doc]** this file (the index). ← landed
2. **[debt.yaml]** file D-168…D-174 (verified/code-read); re-anchor §C/§D;
   housekeeping §E; annotate §F. *Investigate §B before filing those.*
3. **[infra]** `check_debt_id_refs.sh` + gate wiring + CLAUDE.md
   quality-loop step.
4. Each verified correctness row (D-168 range, D-169/170 numeric, D-171
   json, D-174 rest-string) then becomes a normal quality-loop TDD unit,
   drained highest-value-first.
