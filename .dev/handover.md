# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (perf-campaign + quality-loop commits on `cw-from-scratch`).
  Tree clean, 0 unpushed. Mac gate green (187).
- **First on resume MUST be**: **D-183 part (b)** — the `^meta` reader
  macro (`^{:k v} form` / `^:kw form` / `^Type form`) attaching metadata to
  the def-target. Part (a) (`var` special form + `#'` reader) landed
  `925e3283`. Then part (c) (`def` honours target meta → `Var.meta`) and
  part (d) (`defn`/`defmacro` docstring+attr-map lowering, closes D-091).
  Survey + ordering: `private/notes/phaseA26-var-metadata-survey.md`
  (KEY: cljw symbols are meta-less per ADR-0037, so def-target meta rides a
  Form side-channel, not symbol meta — inverts the JVM order).
  Remaining floor after D-183: **D-177** (transducer 1-arg xform, now
  doable), **D-182** (JSON BigInt write-side cheap), D-184/D-173 low.
- **Perf campaign §9.2.S — CLOSED (Debug-measurement correction 2026-06-01).**
  Landed: O-001 `72d7bfcc`, O-002 `0898ba2c`, **O-003/D-180 + ADR-0064**
  `9188820b`, **O-004/D-163 first cycle** `50ccbf3b`. **BUT the alarming
  numbers (121s, 41s, 0.48s startup) were measured on a DEBUG binary**
  (`zig build` defaults Debug, ~10-100× slower). In **ReleaseFast (ships):
  those are ~0.01-0.02s and startup ~ms** — cljw already meets the ms-level
  cold-start mission target (cw v0 claims ~4ms). The algorithmic wins are
  real but the urgency was Debug-inflated; **D-140 startup cache is moot for
  runtime** (Release startup is ms; core is already AOT-restored via
  ADR-0056). Do NOT re-open the perf campaign without a **Release**
  (`scripts/perf.sh`) number proving a real regression.
- **Build-mode / perf-measure policy** (`.claude/rules/perf_measure_release.md`):
  measure speed ONLY via `scripts/perf.sh` (ReleaseFast); NEVER `time
  zig-out/bin/cljw` (Debug). Gate e2e + phase4_* = ReleaseSafe; unit tests +
  dev `zig build` = Debug (speed/diagnostics, never timed).
- **Operating mode** = clj differential sweep (F-011) + quality-loop floor:
  probe via BOTH `clj`+`cljw`, fix at the finished form, commonise.
  Autonomous; loop self-selects per F-002 / ROI.
- **Forbidden**: re-opening landed work (git log = SSOT). JIT/superinstruction
  (D-133, post-M). Re-opening perf without a Release `scripts/perf.sh` number.
  Touching `tree_walk.zig`/`vm.zig` for statics/fields (backend-agnostic;
  diff oracle verifies parity).

## Process discipline (full detail in memory + rules)

- **Never poll a background gate**: launch `run_in_background`, yield, act on the
  completion notification, read once. **`clj -M -e` → `timeout 20`-wrap** +
  bound infinite seqs. **No `\a` char literals through `cljw -e`** (shell eats `\`).
- **Under host load, capture probe output to `/tmp/*.txt` and Read it** (bare reads
  garble). Defender exclusions: re-verify post-reboot (`mdatp exclusion list`).

## Current state

java.lang scalar-class static cluster (A26) + D-166 float printer done.
Scaffolding: standing **`quality-loop floor:` Barrier** + CLAUDE.md Step 0.5
drain (8 floor rows D-168–175) + scaffolding diet (ADR-0062). Invariants:
**F-011** + **F-010** (the floor IS the F-010 quality loop's drain queue).

## Master divergence ledger (compaction-survival)

[`private/notes/phaseA26-clj-differential-oracle.md`](../private/notes/phaseA26-clj-differential-oracle.md)
holds every clj diff (fixed + unresolved + acceptable), the oracle recipe, the
swept categories, the next-sweep candidates (bit methods / Math `*Exact`), and
the remaining Java-interop gap list. **Read it first on resume.** Per-task
notes: `private/notes/phaseA26-*.md`.

## Open debts (full rows in `.dev/debt.md`)

- **Perf §9.2.S CLOSED** (see Resume contract; Debug→Release correction).
  O-001..O-004 + ADR-0064 landed. D-163 later increments + D-140 startup =
  low-ROI / moot in Release. Re-open only with a `scripts/perf.sh` number.
- **Quality-loop floor (resume here)** — **D-183** var-metadata surface
  (part a done `925e3283`; b/c/d remain — see Resume contract); **D-177**
  transducer 1-arg xform; **D-182** JSON BigInt; D-184/D-173 low;
  re-anchored D-086/088; D-175 Lens-C + M5. Index:
  `.dev/tech_debt_consolidation.md`.
- **DISCHARGED**: D-166/167/161/168/169/170/171/172/174/185 + D-087/090/091
  + D-180 + ADR-0064 (transient HAMT map).
- **Structural-deferred (F-003)**: D-164 empty≡nil, D-165 i48→i64, D-178
  `.list`/`.cons` split, D-179 `.string_seq`/`.array_seq`, D-006/036/037/039 zwasm v2.
- **Acceptable divergences**: `(class 5)`→`Long` (ADR-0059); `(float 1/3)` f64;
  set + HAMT-map print order; subnormal `5.0E-324` vs JVM `4.9E-324` (same double).

## Cold-start reading order

handover → `.dev/tech_debt_consolidation.md` (quality-loop floor queue) +
master ledger `private/notes/phaseA26-clj-differential-oracle.md` → CLAUDE.md
(§ Project spirit + Autonomous Workflow + The only stop) → `.dev/project_facts.md`
(F-002 / F-010 / F-011) → `.dev/principle.md` (Bad Smell) → `.dev/reference_clones.md`
(clj oracle). Perf: `.dev/optimizations.md` + `.claude/rules/perf_measure_release.md`
(measure ONLY via `scripts/perf.sh` — Release, never Debug).
