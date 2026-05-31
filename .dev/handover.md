# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (quality-loop commits on `cw-from-scratch`).
  Tree clean, 0 unpushed. Mac gate green (192). **Gate hazard**: the -P8
  parallel e2e pool intermittently times out under host load — run
  `timeout 1800 bash test/run_all.sh --serial-e2e` for a deterministic green
  (memory `gate-parallel-e2e-timeout`).
- **The reasonably-scoped quality-loop floor is FULLY DRAINED** (incl. the
  structural D-184). **First on resume**: pick ONE remaining LARGER STRUCTURAL
  feature, each a fresh deliberate cycle (Step-0 survey + ADR/DA-fork where
  noted) — NOT a quick coverage drain:
  - **D-160 3-arg multi-coll `sequence`** — needs multi-arg transducer steps
    (every xform's step becomes variadic); broad transducer-protocol change.
  - **D-182 read `.number_string`** — i64-overflow JSON integers need the
    cljw BigInt digit-string parser (analyzer-internal, `setString` avoided)
    extracted to a callable layer + the `:bigdec`-vs-Double decimal decision.
  - **D-190** eduction prints `#Eduction[..]` not its seq — needs print-method
    infra (a `print-method`-equivalent / `Sequential` marker).
  - **D-086** defrecord `__extmap` (TypedInstance layout, Phase 8, +ADR);
    **D-088** protocol fqcn ns-scope (tied to D-058/D-079 ns surface).
  - Standing F-003 structural: D-164 empty≡nil, D-165 i48→i64, D-178/179.
- **This session (35 commits)**: full var-metadata (D-183 a-d + D-187 +
  `doc`) + transducer (D-177, D-160 sequence+eduction ADR-0067) surfaces +
  correctness (D-185/188/186/189/182/173) + structural **D-184/ADR-0038**.
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
- **Quality-loop floor — reasonably-scoped DRAINED.** Remaining = larger
  structural features (see Resume contract): D-160 3-arg, D-182 number_string,
  D-190 print-method, D-086/088, D-164/165/178/179. Index:
  `.dev/tech_debt_consolidation.md`.
- **DISCHARGED this session** — D-185/183/177/160/188/186/182(write+read-int)/
  189/187/173/**184** + ADR-0067 + **ADR-0038 amendment**; prior D-166/167/161/
  168/169/170/171/172/174 + D-087/090/091 + D-180 + ADR-0064. Spinoffs:
  D-186/188/189 DONE, D-187 full; D-190 filed (print-method).
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
