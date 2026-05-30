# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (D-161 defmulti↔hierarchy + e2e-clobber fix landed 2026-05-31).
- **Direction (user, 2026-05-30)**: raise **functional completeness FIRST**
  (no premature JIT/superinstruction), **corpus-driven** not AI-probed. Emphasis
  is **STRUCTURAL-DEFECT HUNTING, not ad-hoc gap-filling**: when a large-input/
  edge probe surfaces a wiring fault / unconnected scaffold / representation
  divergence / hidden O(n²) / non-TCO recursion, fix the **finished form
  (F-002)** — do the rework, don't ad-hoc patch the symptom. METHOD + catalog in
  [`.dev/lessons/structural_defect_hunting.md`](lessons/structural_defect_hunting.md)
  (read on resume). Fully autonomous; flexible replanning.
- **First commit on resume MUST be**: resume **structural-defect hunting** per
  the lesson. Next clean units (verified-real gaps, 3x-agreement probe — NO
  primitive + NO core.clj wrapper, all `name_error`): **`satisfies?`** (CLEANEST
  — `rt/__satisfies?` primitive EXISTS at `primitive/protocol.zig`; needs only a
  `(def satisfies? (fn* [p x] (rt/__satisfies? p x)))` wrapper near core.clj's
  protocol block ~L1040; ⚠️ re-probe `(satisfies? P 42)` CLEAN — a load-corrupted
  probe showed a suspicious `true`, confirm the native path isn't a real bug);
  **`extends?`**; **`type`/`class`** (representation design — what does
  `(class 5)` return w/o JVM Class? → ADR depth≥2 + DA fork; `class_name.zig` has
  NATIVE_ENTRIES name→tag to reverse); **ns-introspection** (`find-ns`/`ns-name`/
  `all-ns`/`create-ns`/`intern` — no namespace.zig primitive; env.namespaces is a
  StringHashMap at env.zig getOrCreateNs ~L277); **`resolve`**. OR **D-160**
  sequence/eduction push→pull bridge (big — Step-0 survey first). Always probe
  first (3x). Do NOT ask (Direction-ask smell). **Build-race caution**: chain
  `zig build && <probe>` — a not-yet-relinked binary gives STALE results.
- **Forbidden this session**: re-opening anything landed (sorted collections,
  transducers 1-5, D-159, range/sort/interleave/zipmap crash fixes, dedupe/
  distinct O(n²), mapv/fnil, nested-lazy print, ad-hoc hierarchies, re-seq,
  read-string, eval, D-161) or earlier (AOT, ratio-arith, HAMT, atoms).
  JIT/superinstruction (functional completeness first). Flipping
  `phase_at_least_14` / v0.1.0 (HELD).

## Current state

Mac gate green (169 pre-restart; gate cadence mechanically enforced). AOT-
bootstrap LIVE (ADR-0056). Recent landings (git log is the SSOT): sorted
collections (ADR-0057 LLRB), transducers core-complete (sequence/eduction =
D-160), D-159 sort comparators, 4 crash fixes (non-TCO recursion class CLOSED),
dedupe/distinct O(n²)→O(n), ad-hoc hierarchies, re-seq, read-string, eval
(ADR-0058 D-162), **D-161 defmulti↔hierarchy** (368c4da4), **e2e-clobber fix +
check_e2e_dup.sh gate** (d523b608).

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

Coverage floor heavily advanced. Toward M: finish corpus-style coverage/
robustness sweep → **Phase 15** concurrency (ADRs 0009/0010) → superinstruction/
fusion → narrow ARM64 JIT (D-133) → **M** → quality loop. cw-v0 gaps in
`.dev/cw_v0_parity_and_gap_plan.md`.

## Open debts (named; full rows in `.dev/debt.md`)

- **D-160** sequence/eduction (push→pull transducer bridge). **D-158** corpus-
  driven validation. **D-139** AOT param-name. **D-134** letfn + mapcat-multi-
  coll. **D-155/156** HAMT collision/dissoc-collapse. **D-150** VM ctor parity.
  **D-153** `(cons x lazy)` count. **D-152** diff oracle `.clj` closures.
  **D-131** built-app non-core. **D-117/118** nREPL (Phase-15). **D-133** JIT.
- **Verified-real gaps (2026-05-31, clean 3x probe)**: `type`/`class`/`resolve`/
  `find-ns`/`ns-name`/`ns-publics`/`create-ns`/`intern`/`satisfies?`/`extends?`
  → name_error (no primitive + no wrapper). `re-find` w/ #"regex" literal →
  not_implemented. These are the next coverage units (see First-commit).
- **Sweep gaps (low)**: `mapv`/`interleave` N-coll variadic; `reductions` O(n²);
  `uuid?` repr; `ns-interns` returns ns-map count; lazy-as-map-value `#<lazy_seq>`.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-010) → `.dev/principle.md` (Bad Smell + depths) →
`.dev/lessons/structural_defect_hunting.md` (resume MODE) →
`.dev/core_coverage_gaps.md` (sweep queue) →
`private/notes/phaseA26-CHANNEL-INCIDENT-resume.md` (the incident bridge) +
`private/notes/phaseA26-*.md`.

## Stopped — user requested

User instruction (2026-05-31): restarting the machine (host load ~5 from an
orphan OrbStack VM + iOS Simulator + 3 parallel claude sessions corrupted tool
output — empty/duplicated/leaked results; cause + discipline saved to memory
`tool-channel-corrupts-under-load` + `private/notes/phaseA26-CHANNEL-INCIDENT-resume.md`).
Before restart: wire the session's knowledge + audit the resume chain (Done —
D-161 debt row discharged, verified gaps + channel discipline wired here).
Resume per the First-commit line.

**Channel/load discipline**: if tool output looks empty/duplicated/contradictory,
suspect host load first (`uptime`; `ps -axo pid,pcpu,etime,command|sort -k3 -rn`);
write every output to a SENTINEL-marked /tmp file + trust only tagged lines; run
critical probes 3x for agreement; trust `git log` from a file; `Smell-audited:
<DIGIT>:` (hook rejects `depth`).
