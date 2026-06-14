# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT). **NORMAL PUSH MODE** (user 2026-06-15:
  local-accumulation LIFTED). After each unit's smoke-green commit, `git push origin
  main` immediately (Step 6). `build.zig.zon` `.zwasm` is **SHA-PINNED** to a pushed
  clojurewasm/zwasm commit (`#412966f7…` + content `.hash`, `lazy`) so others build
  reproducibly — NOT the local `../zwasm_from_scratch` path. Advance the pin via
  `zig fetch "git+https://github.com/clojurewasm/zwasm.git#<pushed-SHA>"` (prints the
  hash) then hand-edit `.url`+`.hash`+`.lazy` (the `--save` form mangles a prior
  `.path` entry). Procedure/rationale: zwasm `docs/consuming_prerelease_zwasm.md`.
  Per-commit = smoke; `-Dwasm` now fetches zwasm from git (default build is
  zwasm-lazy, untouched). NOTE: reproducibility-for-others also needs read access to
  the (currently pre-tag) clojurewasm/zwasm repo — user's external action.

- **First task on resume**: **drain `.dev/debt.yaml` `active:` TOP-DOWN.** The
  2026-06-15 ledger audit re-ordered `active:` EASIEST-FIRST (quick-wins → PERF
  cluster → large) and split the never-closing trackers + defer-bucket into a new
  `standing:` section. **The loop is FULLY AUTONOMOUS — no open user-judgment items**
  (all reflected this session). Standing user decisions (durable: memory
  `debt-ledger-audit-decisions`):
  - **work order** = quick-wins (trivial/small) → then **perf 専念** (D-386 dispatch →
    narrow ARM64 JIT, beat-Python north-star); the `active:` order encodes this.
  - **future bucket** (broad JIT / CLJS→JS / C-FFI / gen-GC / virtual-threads /
    out-of-proc isolation / wasm structural-future) = **defer INDEFINITELY** — NEVER
    auto-start; lives in `standing:`.
  - **debt.yaml** = `active:`(drain easiest-first) / `standing:`(NOT drained) /
    `discharged:`. Self-select drain-units from `active:` ONLY; correctness/clj-parity
    floor outranks coverage.
  First `active:` rows (easiest-first): D-023, D-025, D-022, D-042, D-046, D-222, D-228,
  D-240, D-241 … → (medium) … → PERF cluster (D-386 et al) → large. The PERF cluster is
  the "then perf 専念" phase.
  - **Reads: `.dev/project_facts.md` F-015 + ADR-0142 + ROADMAP §9.0 + debt.yaml header
    + `active:` top rows** + memory `debt-ledger-audit-decisions`. Discharging a row =
    MOVE to `discharged:` (don't inline-discharge), or let D-175 batch-relocate.

- **This session landed (git log = SSOT)** — the full Track R (D-440) arc + the
  zwasm release:
  - **Track R R1-R5** (F-015 / ADR-0141 / **ADR-0142**): R1 concurrency parity
    (D-441 agent ctor options + await-for + swap-vals!/reset-vals! + io!, corpus-locked);
    R2 accurate-position survey; R3 §9 gap-area reframe (ADR-0142, **D-443** filed);
    R4 future-row re-barriers → gap-area; R5 retired `phase_at_least_N` +
    CLAUDE.md/principle.md → gap-area model. Stale agent e2e (the full gate caught it)
    updated for the landed options.
  - **zwasm SHA-pin + push restored**: `build.zig.zon` `.zwasm` is now a content-hash
    git pin (`#412966f7`); the 2026-06-14 local-accumulation/no-push override **LIFTED**;
    ~30 accumulated commits released to origin (memory `local-accumulation-sweep-phase`
    = ENDED). Two full gates green (356/356) against the git-pinned zwasm.
  - **DEBT-LEDGER AUDIT** (user-directed; 6-agent code+git fan-out over all 121 open-ish
    rows): 58 rows discharged (23 silently-resolved + 35 already-DONE-status that sat in
    active and re-surfaced as "remaining"); new `standing:` section (30 rows); `active:`
    (68) re-ordered easiest-first. 445 rows preserved, parse/dup/refs clean.

  SAFETY: `clj` oracle batches need `-J-Xmx2g` + bounded seqs (memory
  `clj_oracle_heap_cap`); register every new e2e in run_all.sh same-commit; **the
  `--smoke` tier does NOT run unnamed e2e steps** — name the changed e2e step, or the
  batched full gate catches the miss (it just did, for the agent options e2e).

  **State**: near-complete (F-015); §9 is the **gap-area model** (§9.0). zwasm
  SHA-pinned + interp-embedded. **Normal push mode** (Step 6 push per commit).

- **Forbidden this session**: `git push --force*`; bare `zig build` for any
  scripted / probe path (ADR-0133 — use a ReleaseSafe binary). (Local-accumulation /
  no-push is LIFTED — push per Step 6.)

## Stopped — user requested

User instruction (2026-06-15): debt台帳がコード現実と乖離している → 全 active 行を
コード真実 + git log で監査し、解決済みを discharge、再表示されないよう整理、解消容易順に
配置、ユーザー判断が要る件は今セッションで確定、次のクリアセッションから完全自律で進める
状態にして止めて。**Done**: 6-agent audit (121 rows) → 58 discharged + `standing:`
split + `active:` easiest-first; 3 user decisions captured (work-order quick-wins→perf /
future-bucket defer-indefinitely / 3-section ledger — memory `debt-ledger-audit-decisions`).
No open user-judgment items remain → resume is fully autonomous: drain `active:` top-down.
This stop applies to THIS session only; the next `/continue` resumes the loop (delete this
section on resume per handover_framing).

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-015** (the completion-grade posture — read
FIRST) → **`.dev/decisions/0142_*.md`** (the §9 gap-area reframe; supersedes the
old phase-queue model) → **ROADMAP §9.0** (the gap-area model + the
phase-number→gap-area redirect) → the chosen gap area's draining `.dev/debt.yaml`
rows. Track R (D-440) substantive arc is DONE; the loop self-selects the next
gap-area unit (CLAUDE.md § "When the active work unit completes"). clj oracle =
`~/Documents/OSS/clojure/` + `clj -J-Xmx2g -M` (`timeout 60`). SAFETY: bounded seqs
+ `-J-Xmx2g`; name changed e2e steps to `--smoke` (unnamed e2e are NOT run);
register new e2e in run_all.sh same-commit; new debt rows via Edit (quoted id),
NOT `yq +=` (yaml_ssot_yq.md Golden-rule #4).

