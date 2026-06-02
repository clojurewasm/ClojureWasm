# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (D-202(1) field-scope + D-201 letfn + debt.yaml
  migration on `cw-from-scratch`). Gate green on `vm` (Mac 200+; ADR-0070 /
  F-012). debt ledger is now **`.dev/debt.yaml`** (structured YAML; the former
  `.dev/debt.md` md-table bloated to 800KB — migrated lossless, 264KB).
- **First commit on resume MUST be: implement D-203 / ADR-0072** —
  `extend-type` / `extend-protocol` over a NATIVE or java class
  (`(extend-type Long P …)` / `(extend-type String P …)`). Design + mandatory
  Devil's-advocate analysis are DONE and recorded in **ADR-0072 (Proposed)** +
  the D-203 entry (`file:line` refs there). TDD from an e2e red. Flip ADR-0072
  to Accepted after it lands. NOTE: the old D-202(2) "resolveJavaSurface" plan
  is WRONG (Step 0.6 finding) — use the native-descriptor-identity approach in
  ADR-0072 (resolve native-class symbols in `analyzeSymbol`).
  Then: **D-200 — EDN `#uuid`/`#inst` tagged literals** (`#uuid` needs a
  UUID-type ADR — partial-string-parity vs a real type).
  **Verify via e2e** (top-level forms) — `clj_diff_sweep` can NOT batch-verify
  define-heavy poly/reader forms (wraps each line in `(prn …)` → `<clj-missing>`).
  Other follow-ups: (a) the DA Alt-2 name↔Tag SSOT consolidation deferred in
  D-203; (b) v0.1.0-tag closeout (Phase 14.14).
- **Forbidden**: re-sweeping COVERAGE.md § Swept areas wholesale; seizing the
  F-003 structural-deferred rows (D-164 empty≡nil, D-165 i48→i64, D-086/088/
  178/179) incrementally — big-bang, user-gated; re-opening landed work
  (git log = SSOT); perf without a Release `scripts/perf.sh` number.

## Stopped — user requested

User instruction (2026-06-02): "[when you reach a good break] `.dev/debt.md`
got bloated by the global md-table-align into a huge whitespace-padded table;
either stop that treatment or make debt.md itself a structured artifact, and
make every place that references / auto-processes it follow. My preference is
YAML, but implement the best way you decide (don't present options — choose
autonomously). After that, audit the wiring / reference chain for the next
session, then stop." DONE: migrated to `.dev/debt.yaml` (lossless, reconstruction-
verified; `scripts/migrate_debt_to_yaml.py`); updated all auto-processors
(`check_debt_id_refs.sh`, `check_provisional_sync.sh:171` functional regex,
`audit_scaffolding/CHECKS.md` yq, `debt_dedup.md`) + 33 prose refs; deleted
debt.md; `check_md_tables.sh` skips non-.md so bloat can't recur. **Resume**:
the next `/continue` implements D-203 / ADR-0072 — this stop does not carry
across sessions (CLAUDE.md § The only stop).

## Discharged this session (git log = SSOT; full rows in `.dev/debt.yaml`)

- **D-202(1)** defrecord/deftype bare-field refs in protocol method bodies
  (`lowerDefType` wraps each body in a field `let*` over `(.field inst)`; Step
  0.6 corrected the debt row's wrong shadowing claim — param shadows field).
- **D-201** `letfn` / `letfn*` (dedicated `letfn_node` + analyzer + TreeWalk +
  VM `op_letfn_patch` + macro; mutual recursion via post-alloc closure patch).
- **debt.yaml migration** (this stop's task) + **ADR-0072 (Proposed)** for
  D-203 (native-class protocol extension; design + DA preserved, code pending).

## Remaining (pointers — full text in `.dev/debt.yaml` + COVERAGE.md)

- **Moderate features**: D-203/ADR-0072 (next), D-200 (see Resume contract).
- **Structural-deferred (F-003, big-bang, user-gated)**: D-164 empty≡nil
  (highest-leverage single fix), D-165 i48→i64, D-086/088/178/179, D-105.
- **v0.1.0 closeout**: Phase 14.14 — exit-smoke + `phase_at_least_14` flip +
  tag (D-047 unblocks ≥2^64 on Linux).
- **Perf §9.2.S CLOSED**: Release startup is ms; re-open ONLY with a Release
  `scripts/perf.sh` regression number. D-140 startup = moot.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate: `timeout 1800 bash test/run_all.sh --serial-e2e` (the -P8 pool times
  out under load — memory `gate-parallel-e2e-timeout`). Never poll a bg gate.
  `clj -M -e` → `timeout 20`-wrap + bound infinite seqs. Speed ONLY via
  `scripts/perf.sh` (Release) — `.claude/rules/perf_measure_release.md`.

## Cold-start reading order (tracked-only)

handover → `test/diff/clj_corpus/COVERAGE.md` (sweep state) +
`.claude/rules/clj_diff_sweep.md` → `.dev/debt.yaml` (open rows: D-200/201/202)
→ CLAUDE.md (§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002/010/011/012) → `.dev/principle.md` (Bad Smell).
