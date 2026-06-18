# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: **continue the clj-parity quality loop**
  (post-M F-010/F-011), self-selecting from the options below — the single-expr
  differential sweep has largely SATURATED (the last several fresh surfaces found 0
  new real bugs). Disposition EVERY DIFF — bug→fix (clj-oracle-grounded, corpus +
  e2e) OR accepted→AD-NNN (derives_from + pin) per `accepted_divergences.md`. DONE
  this campaign (clean / fixed): arity envelopes, exception catchability + specific-
  class, print fidelity, reader hygiene, assert message, sorted-coll equality, +
  WHOLE-PROGRAM integration (5 mini-programs in `private/arity_sweep/mini*.clj` all
  clj-identical modulo accepted ADs), core libs (zip/data/walk/edn/set), numeric
  tower, macros (`when` now byte-matches clj). Highest-value remaining options, in
  order: (1) the deferred structural debt — D-460 (sorted coll as map key, rt-free
  keyEqValue), D-461 (eager-load require semantics — F-003 owner call), D-446
  (multidim arrays); (2) a few
  not-yet-swept surfaces likely thin: date/time (interop-heavy), spec, deeper
  transducers; (3) the `clj_diff_sweep` harness gap — it CANNOT sweep top-level
  forms (defrecord/defprotocol/deftype error inside its `(prn …)` wrapper), so use
  the mini-program (file-diff) approach for those, as `mini*.clj` do.

- **Forbidden this session**: JIT integration (D-133 — user-fenced 2026-06-16; plan
  in `private/notes/9.2.S-d133-jit-survey.md § INTEGRATION`). `git push --force*`.
  Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory
  `zig_build_test_needs_dwasm`). Bare `zig build` for scripted/probe (ADR-0133 —
  ReleaseSafe). A reader-macro NS-qualification MUST use `rt/` (the only core ns
  resolvable in the core.clj-less diff fixture), NOT `clojure.core/` (AD-038 lesson).

## Last landed (git log = SSOT; all pushed)

**clj-parity differential-fidelity campaign** (post-M F-010/F-011 quality loop, this
session, 11 commits): D-446 arity-envelope sweep (n-ary map/mapv/mapcat/list*,
bit-and-not, resolve 2-arg, typed array ctors 2-arg + AD-036); then a broad
exception/print/reader fidelity arc — deref/conversion/ns arg-type errors made
CATCHABLE (were uncatchable `feature_not_supported`); subvec/peek/pop/replace/
requiring-resolve/io ex-info → clj's specific class (IndexOutOfBounds / IllegalState
/ ClassCast / IllegalArgument); a bare chunked_cons now prints its elements (was
`#<chunked_cons>`); `@x` reader NS-qualified (`rt/deref`) to fix a local-`deref`
capture bug. Accepted divergences recorded: AD-036 (array 2-arg uniform fill),
AD-037 (`(str lazy_seq)` → elements vs clj identity hash), AD-038 (`@` → `rt/deref`
vs clojure.core), AD-039 (`#()` deterministic `%1` vs gensym), AD-040 (cond
macroexpand full vs clj's recursive form). Then: assert message includes the form
(clj parity); sorted-set/sorted-map `=` by elements across impls; `when` macroexpand
byte-matches clj; a whole-program integration e2e (`phase14_realworld_program`).
Value-parity verified clean (many sweeps + 5 mini-programs, 0 non-AD/non-F-005 diffs).

**Open residuals** (`.dev/debt.yaml`): D-446 (multidim aget/aset/aset-* variadic,
perf-vs-F-009); D-460 (sorted coll as map key / set element — rt-free keyEqValue);
D-461 (eager-load require semantics — F-003 owner decision). (D-459 exception-CLASS
fidelity DISCHARGED 2026-06-18 — see below.)

## Perf campaign (PAUSED behind the active flag; not the current task)

`.dev/.perf_campaign_active` is SET but the loop is in the quality sweep, not perf.
If the user re-opens perf: the only remaining accessible lever is D-386(a) (inline
`stepOnce` SP-marshalling, a risky UAF-class cycle — fresh focus + the
`CLJW_GC_TORTURE_ALLOC` safety net); JIT D-133 is user-fenced. Full perf state:
ADR-0148 + `private/notes/9.2.S-perf-remeasure-2026-06-17.md`.

## Cold-start reading order (resume)

handover → `.dev/project_facts.md` (F-002 / F-010 / F-011) →
`.claude/rules/clj_diff_sweep.md` + `accepted_divergences.md` (the sweep + AD
discipline) → `.dev/accepted_divergences.yaml` (AD-001…039) → `.dev/debt.yaml`
D-446 / D-460. memory `clj_diff_sweep_methodology` + `direct-explore-fork-mechanical`.

## Stopped — user requested

User instruction (2026-06-18): "きりの良い所で参照チェーン監査して停止してください。"
(Finish at a clean point, run the reference-chain audit, then stop.) Done: D-459
exception-class fidelity batch landed + pushed; reference-chain audit CLEAN
(`arg_value_invalid` defined+used no orphan, no dangling `format_conversion_invalid`,
`big_decimal.toFloat` 2 callers, AD-gate 39 + `check_debt_id_refs` pass, corpus +
e2e wired). Resume: continue the clj-parity quality loop, self-selecting the next
unit (D-460 / D-461 / D-446 or a fresh surface) per the Resume contract above.
