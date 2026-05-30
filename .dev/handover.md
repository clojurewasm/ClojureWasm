# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (D-161 defmulti↔hierarchy + e2e-clobber fix landed 2026-05-31).
- **Direction (user, 2026-05-30)**: raise **functional completeness FIRST**
  (no premature JIT/superinstruction), **corpus-driven** not AI-probed. The
  emphasis is now **STRUCTURAL-DEFECT HUNTING, not ad-hoc gap-filling**: when a
  large-input/edge probe surfaces a wiring fault / unconnected scaffold /
  representation divergence / hidden O(n²) / non-TCO recursion, fix the
  **finished form (F-002)** — do the rework, don't ad-hoc patch the symptom.
  The METHOD + the catalog of patterns found so far live in
  [`.dev/lessons/structural_defect_hunting.md`](lessons/structural_defect_hunting.md)
  (read it on resume). Keep strong cross-session state; clone/copy liberally;
  fully autonomous; flexible replanning.
- **First commit on resume MUST be**: resume **structural-defect hunting** per
  [`.dev/lessons/structural_defect_hunting.md`](lessons/structural_defect_hunting.md).
  Take a known structural defect from the queue (fix per finished form, not
  ad-hoc): **D-160** sequence/eduction push→pull bridge (D-161 defmulti↔hierarchy
  DONE 2026-05-31; D-162 `eval` DONE via ADR-0058); AND keep running large-input/
  edge `cljw -e` sweep batches on unswept surface (interop, dynamic vars, IO,
  deftype/defrecord field access, protocol edge) to find more. Pure missing
  fns (name_error) are the floor — fill if clean, else record the
  architectural blocker as a debt. Always probe first. Do NOT ask
  (Direction-ask smell). **Build-race caution (this env)**: chain `zig build &&
  <probe>` — probing on a not-yet-relinked binary gives STALE results (cost a
  long false "AOT aliasing" detour 2026-05-31).
- **Forbidden this session**: re-opening anything landed this session (sorted
  collections, transducers 1-5, D-159, the range/sort/interleave/zipmap crash
  fixes, dedupe/distinct O(n²) fix, mapv/fnil arities, nested-lazy print,
  ad-hoc hierarchies, re-seq, read-string) or earlier (AOT, ratio-arith, HAMT,
  keyword/data-as-IFn, atoms). Optimization work (JIT / superinstruction) —
  functional completeness first. Flipping `phase_at_least_14` / v0.1.0 (HELD).

## Current state

Mac gate **169/169** green (parallel e2e pool; `SERIAL_STEPS` serial). Gate
cadence mechanically enforced (additive ≤5; shared-code gates every time;
`.dev/.gate_pass` content-hash). AOT-bootstrap LIVE (ADR-0056). Landed this
session (git log is the SSOT): **sorted collections** complete (ADR-0057 LLRB —
build/read/delete/`-by`/rseq/reversible?/subseq/rsubseq + print/IFn/GC);
**transducers core-complete** (reduced surface + all arities + cat + completing/
transduce/3-arg-into + halt-when; `sequence`/`eduction` = D-160); **D-159**
sort/sort-by comparators; **4 crash fixes** (range/sort/interleave/zipmap stack
overflows → loop/recur — class CLOSED via systematic probe); **dedupe/distinct**
O(n²)→O(n) (transducer delegation); **mapv** multi-coll + **fnil** 2/3-default;
**nested-lazy print** (deepRealize); **ad-hoc hierarchies** (isa?/derive/…,
atom-backed, class? branches dropped); **re-seq** (+ re-find-from); **read-string**
(core==edn, no eval-reader); **eval** (ADR-0058 D-162: typed `driver.evalValue`
verb + `rt.macro_table` borrow; built-in macros expand, user macros via env Vars);
**D-161 defmulti↔hierarchy** (expandDefmulti threads `-global-hierarchy` →
derefHierarchy derefs atom → getMethod extracts `:ancestors` + cache invalidates
on snapshot identity; 5 new dispatch e2e); **e2e clobber fix** (phase14_hierarchy.sh
had been byte-overwritten with phase7_multimethod.sh — silent zero-coverage; restored
+ added `check_e2e_dup.sh` gate guard).

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

Coverage floor heavily advanced. Remaining toward M: finish the corpus-style
coverage/robustness sweep → **Phase 15** concurrency (ADRs 0009/0010) →
superinstruction/fusion → narrow ARM64 JIT (D-133) → **M** → quality loop.
cw-v0 gaps in `.dev/cw_v0_parity_and_gap_plan.md`.

## Open debts (named; full rows in `.dev/debt.md`)

- **D-160** sequence/eduction (need push→pull transducer bridge). **D-158**
  corpus-driven validation (clojuredocs walkthrough → lib test suites). **D-139**
  AOT param-name fidelity. **D-134** letfn + re-seq + mapcat-multi-coll residuals.
  **D-155/156** HAMT collision-bucket / dissoc inline-collapse. **D-150** VM ctor
  parity. **D-153** `(cons x lazy)` count. **D-152** diff oracle `.clj` closures.
  **D-131** built-app non-core. **D-117/118** nREPL (Phase-15). **D-133** JIT floor.
- **Sweep gaps (low priority)**: `mapv`/`interleave` N-coll variadic; `reductions`
  O(n²); `uuid?`/`type`/`class` (representation/JVM-Class divergence — design first);
  lazy-as-map-value still `#<lazy_seq>` (deepRealize covers the seq family only).

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The only
stop) → `.dev/project_facts.md` (F-010 + edge mission) → `.dev/principle.md`
(Bad Smell + four depths + structural imagination) →
`.dev/lessons/structural_defect_hunting.md` (the resume MODE + defect catalog)
→ `.dev/core_coverage_gaps.md` (sweep work-queue) →
`private/notes/phaseA26-*.md` (sorted / transducers survey + task notes).

## Stopped — user requested

User instruction (2026-05-31): restarting the machine (load 5 from an orphan
OrbStack VM + iOS Simulator + 3 parallel claude sessions was corrupting tool
output — empty/duplicated/leaked results; cause + discipline in
[`private/notes/phaseA26-CHANNEL-INCIDENT-resume.md`](../private/notes/phaseA26-CHANNEL-INCIDENT-resume.md)
and saved to memory). Before restart: wire the session's knowledge + audit the
resume reference chain. (Done: D-161-done + verified-real-gaps + channel/load
discipline wired into Resume contract above; D-161 debt.md row left as the
explicit first-commit fix because surgical Edits on the corrupted channel were
unsafe — deferred to the clean post-restart session.) Resume per the
First-commit line.

**Channel/load discipline for resume**: chain `zig build && <probe>` (a
not-yet-relinked binary gives STALE results); write every command's output to a
SENTINEL-marked /tmp file and trust only sentinel-tagged lines (the channel
drops/duplicates/leaks under load); run critical probes 3x and require
agreement; trust `git log`/`git rev-parse` from a file over streamed stdout;
`Smell-audited: <DIGIT>: …` (the push hook rejects the word `depth`).
