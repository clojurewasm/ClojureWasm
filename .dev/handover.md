# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (perf-campaign commits on `cw-from-scratch`).
  Tree clean, 0 unpushed. Mac gate green (180).
- **First on resume MUST be**: **ROADMAP §9.2.S Performance tuning campaign**
  (user-directed pull-forward, ADR-0063, ROI-ordered, PERF-marked →
  `.dev/optimizations.md` SSOT). Start at **D-163 — map/filter/take
  reduce-fusion** (cw v0 `fusedReduce`: collapse a lazy chain to a 0-alloc
  pass over the base; `.range` O-001 + the chunked-cons seq are the
  substrate). **Own ADR** (separate from ADR-0063). `(count (map inc (range
  1e5)))` ≈ 42s ≈ 420µs/elem (lazy_seq thunk per element). Then D-140
  startup bootstrap cache. DONE: O-001 range `72d7bfcc`, O-002 reduce-vector
  `0898ba2c`, **O-003/D-180** bulk `vector.fromSlice` (persistent! O(n) +
  into/vec transient routing; `(count (vec (range 1e6)))` 121s → 2.4s).
- **Then** quality-loop floor (D-169/170 quot/int on tower, D-171 json float,
  D-172 Math *Exact, D-174 rest char-seq; D-173 low) — D-168 DONE.
- **Operating mode** = clj differential sweep (F-011) + perf campaign (§9.2.S):
  probe via BOTH `clj`+`cljw`, fix at the finished form, commonise; perf =
  measure before/after + `// PERF:` marker + optimizations.md row per win.
  Autonomous; loop self-selects per F-002 / ROI.
- **Forbidden**: re-opening anything landed (git log = SSOT). JIT/superinstruction
  (deferred to §9.2.R / D-133 — NOT the D-163 reduce-fusion that is now NEXT).
  Touching `tree_walk.zig`/`vm.zig` for statics/fields
  (they resolve to `.constant` Node / shared builtins — backend-agnostic; the
  diff oracle verifies parity).

## Process discipline (load incident 2026-05-31 — full detail in memory + rules)

- **Never poll a background gate** (`sleep N; cmd` is harness-blocked): launch
  `run_in_background`, yield, act on the completion notification, read once.
- **`clj -M -e` MUST be `timeout 20`-wrapped** (infinite-seq orphan → ~160% CPU).
- **Never pass `\a`-style char literals through `cljw -e`** (shell eats `\`); use
  `(char N)`.
- **Under load, capture probe output to `/tmp/*.txt` and Read it**; bare reads can
  be garbled. One Claude session per repo — 2026-05-31 confirmed only this
  session on cljw (others were zwasm/myskill).
- **Defender exclusions** (`mdatp exclusion`): verify post-reboot via
  `mdatp exclusion list`, re-add any dropped (zig + project `.zig-cache`/`zig-out`
  + `~/.cache/zig`).

## Current state

java.lang scalar-class **static cluster COMPLETE** (A26) + **D-166 float
printer** done. Two user-directed scaffolding passes since: tech-debt
consolidation (`b76e9574`..`a9f35018`: standing **`quality-loop floor:`
Barrier** + **CLAUDE.md Step 0.5 drain** + `check_debt_id_refs.sh` gate
guardrail + 8 floor rows D-168–175), and the **scaffolding diet**
(`7a73d27d`, ADR-0062): 200K-window default, pruned always-on rules,
project-scoped MCP disable, de-duplicated SessionStart/PostCompact hooks.
Invariants: **F-011** + **F-010** (the floor IS the F-010 quality loop's
drain queue).

## Master divergence ledger (compaction-survival)

[`private/notes/phaseA26-clj-differential-oracle.md`](../private/notes/phaseA26-clj-differential-oracle.md)
holds every clj diff (fixed + unresolved + acceptable), the oracle recipe, the
swept categories, the next-sweep candidates (bit methods / Math `*Exact`), and
the remaining Java-interop gap list. **Read it first on resume.** Per-task
notes: `private/notes/phaseA26-*.md`.

## Open debts (full rows in `.dev/debt.md`)

- **Perf campaign (ROADMAP §9.2.S, ACTIVE)** — **D-180** bulk `persistent!` /
  `vector.fromSlice` (NEXT) → **D-163** map/filter reduce-fusion (own ADR) →
  **D-140** startup bootstrap cache. Done: O-001/O-002. Index: `.dev/optimizations.md`.
- **Quality-loop floor (after the perf campaign)** — D-169/170 quot/int on the
  tower, D-171 json float, D-172 Math *Exact, D-174 rest char-seq, D-173 (low);
  re-anchored D-086/087/088/090/091; D-175 Lens-C + M5. Index:
  `.dev/tech_debt_consolidation.md`.
- **D-166 / D-167 / D-161 / D-168 DISCHARGED**.
- **Structural-deferred (F-003)**: D-164 empty-seq≡nil, D-165 i48→i64 long prints
  `N`, D-178 `.list`/`.cons` split, D-179 `.string_seq`/`.array_seq`,
  D-006/036/037/039 zwasm v2.
- **Acceptable divergences**: `(class 5)`→`Long` (ADR-0059); `(float 1/3)` f64;
  set print order; subnormal `5.0E-324` vs JVM `4.9E-324` (same double).

## Cold-start reading order

handover → **`.dev/ROADMAP.md` §9.2.S** (the active perf campaign + ROI-ordered
units) → **`.dev/optimizations.md`** (O-001/O-002 done; D-180/D-140 candidates +
measured numbers) → **ADR-0063** (`.dev/decisions/0063_compact_range_value.md` —
perf-pull-forward + PERF-marker/SSOT governance) → **D-180 row in `.dev/debt.md`**
→ CLAUDE.md (§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002 / F-010 / F-011) → `.dev/principle.md` (Bad Smell)
→ `.dev/reference_clones.md` (clj oracle + cw v0 precedent). Quality-loop-floor
fallback (after the perf campaign): `.dev/tech_debt_consolidation.md` + master
ledger `private/notes/phaseA26-clj-differential-oracle.md`.
