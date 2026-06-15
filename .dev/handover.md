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
  **First task on resume: continue top-down from D-321** (the next un-dispositioned
  active row). Drained/disposed this session: D-046/228/248/317 discharged; D-246
  (a) DONE / (b)(c) explicit-defer; D-240/D-241 re-barriered (deferred/feature-gated);
  D-023/025/022 opportunistic (barriers unmet); D-042 = audit_scaffolding's領分.
  Next clj-parity DOs: **D-321** (FileNotFoundException Kind), **D-322** (PARTIAL),
  **D-433** (exception str/toString vs pr/pr-str — a clear parity bug). Then → PERF
  cluster (D-386 dispatch → ARM64 JIT, the beat-Python north-star).
  - **GUARDRAIL (user 2026-06-15, durable)**: do NOT defer under progress pressure.
    Re-evaluate every candidate-defer against finished-form / あるべき論. If unifying
    REDUCES a parity gap AND does not scatter the design, DO it even if laborious
    (D-317 was a wrongly-deferred parity gap this session — reversed + landed). Genuine
    defers are fine, but make the **do/don't EXPLICIT** with a reason — avoid vague
    "workload-gated" defer-residue (see the D-246/D-240 re-barriers for the shape).
  - **Reads: `.dev/project_facts.md` F-015 + ADR-0142 + ROADMAP §9.0 + debt.yaml header
    + `active:` top rows** + memory `debt-ledger-audit-decisions`. Discharging a row =
    MOVE to `discharged:` (don't inline-discharge), or let D-175 batch-relocate.

- **This session landed (git log = SSOT)** — 6 commits, HEAD `4ed40f93`:
  - **D-046** (ADR-0143): LazySeq.force thread-safe — inline lock-free CAS-claim
    atomic flag on `realized_flag` (lock-free acquire read, at-most-once, safepoint
    loser-spin; rejected off-heap Io.Mutex + futex-unavailable). 8-thread test.
  - **D-228**: nested syntax-quote depth-correct (fresh-gmap inner-expand → outer
    re-walk; clj-verified; corpus). **D-317**: IPersistentVector extend-protocol
    reaches MapEntry (SSOT-derived extend-target; was a parity gap). **D-248**
    (ADR-0027 am6): Group D NaN-box slot reorg (Clojure internals up, wasm to tail).
  - **D-246(a)**: atom watches/validator/meta atomic. **D-241** re-barriered
    (substance was already done by ADR-0096; feature-gated residual). **D-240**
    re-barriered (fix direction confirmed = install java surfaces in diff Fixture;
    deferred on an unexplained eval_budget/compare interaction — see the row).
  - **GATE STATUS**: last FULL gate (356/356) was at D-248 (`3cab52fa`). Since then
    D-317 (smoke 5/5) + D-246a (`zig build test -Dwasm` 1109/1109, full smoke NOT
    run — fence-only). **Run a full gate (`bash scripts/run_gate.sh`) early on resume**
    — 2 commits rode past the last full gate, and the D-246a content has no matching
    smoke/gate fingerprint. (warm caches → ~2-3min; cold → the inner 300s timeout
    fires before e2e, re-run warm.)

  SAFETY: `clj` batches need `-J-Xmx2g` + bounded seqs; `zig build test` needs
  `-Dwasm` (memory `zig_build_test_needs_dwasm` — bare drops the bootstrap_core embed
  → ~7 false fails); name changed e2e steps to `--smoke`; new debt rows via Edit.
  **State**: near-complete (F-015); §9 gap-area model; zwasm SHA-pinned. Normal push.

- **Forbidden this session**: `git push --force*`; bare `zig build test` WITHOUT
  `-Dwasm` (false fails); bare `zig build` for scripted/probe (ADR-0133 — ReleaseSafe).

## Stopped — user requested

User instruction (2026-06-15): 「ちょっとPC負荷が高まってきたので、クリアセッションから
continueだけで継続できる、配線・参照チェーン監査をして止めてください（きりのよいところで
OK）」. Done: the wiring / reference-chain audit is CLEAN — debt.yaml parses + no dup
ids; `check_debt_id_refs` reports "all cited debt IDs resolve" (the D-014 / D-16 /
D-2026 comm-recipe hits are prose substring / a `D-2026-06-13` typo, NOT real
phantoms); ADR-0143/0027/0116/0096 resolve; this session's discharged rows present.
HEAD `4ed40f93` is clean + pushed. This stop applies to THIS session only; the next
`/continue` resumes the loop normally (delete this section on resume): run a full gate
first (see GATE STATUS above), then continue top-down from D-321 under the GUARDRAIL.

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

