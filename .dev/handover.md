# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume**: self-select highest-value UNBLOCKED unit. Current
  pick = **D-458** (cl-format `V`/`#` runtime-valued directive params in `cl-dir`,
  barrier none, finished-form spec in the debt row). NOTE the Step-0.5 finding
  below: the security gap-area-II cluster is uniformly BARRIERED, not actionable.

- **B/C sweep done (2026-06-20)**: the user's "sweep the ADR-sequenced (B) +
  ADR-deferred-follow-on (C) rows" — landed D-337/327/326 (B + class-name),
  D-293 + D-464 (class-level isa? + the multimethod isa?-dispatch gap D-293 had
  MIS-recorded), D-437 narrowed+corpus, D-442 part 1 (executor raises + sugars);
  D-241 verified principled-deferred; D-453/D-381 correctly perf/big-cleanup-scoped.
  Broader remaining clusters (still the real work) —
  - **Security (gap area II — ~10 rows, but ALL BARRIERED as of the 2026-06-20
    sweep, NOT free coverage)**: D-339 slowloris = blocked-by Phase-15 cancellable
    Io (F-003); D-347/349 wasm/run fuel+capture = zwasm-side (F-001); D-338
    host-import allowlist = reservation until a host import is wired; D-346/353 =
    no live threat / no use case yet. Don't force these (F-001/F-003). Revisit when
    Phase-15 Io lands or a real threat/use-case surfaces.
  - **Perf (D-450 fastest-script target, ADR-0148 — UNMET; `.perf_campaign_active`
    is SET)**: only risky/fenced levers left — D-386(a) inline stepOnce (UAF-class),
    JIT D-133 user-fenced.
  - **clj-parity PARTIAL residuals (mostly niche)**: D-458 cl-format V/#, D-431
    Throwable, D-446 multidim array, D-462 ZonedDateTime (tz-DB-blocked), D-463
    clojure.test per-var events, D-410 java.text.
  - **Concurrency (gap area I)**: D-258 agent-race flake (recurring),
    D-239/245/255/442 PARTIAL.
  This is a genuine campaign-boundary reassessment, not a queue-pop — but the
  remaining work is substantial, not thin.

- **Forbidden this session**: JIT integration (D-133 — user-fenced 2026-06-16; plan
  in `private/notes/9.2.S-d133-jit-survey.md § INTEGRATION`). `git push --force*`.
  Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory
  `zig_build_test_needs_dwasm`). Bare `zig build` for scripted/probe (ADR-0133 —
  ReleaseSafe). A reader-macro NS-qualification MUST use `rt/` (the only core ns
  resolvable in the core.clj-less diff fixture), NOT `clojure.core/` (AD-038 lesson).

## Last landed (git log = SSOT; all pushed)

**D-442 part 2 / ADR-0155** (this session): the agent legacy/executor surface is now
8/8. `*agent*` (interned Zig-side + cached `rt.agent_var`, drainer-bound around each
action body), `release-pending-sends` (flush `nested_pending` + re-arm to `.empty`,
return count), `shutdown-agents` (process-global flag). PREMISE CORRECTION: ADR-0155
part-1 assumed post-shutdown send THROWS; the clj oracle proved clj DROPS it (send
returns the agent, no throw). 2nd DA fork → Alt A (clj-faithful drop) on F-011
priority; new **AD-046** scopes the residual (clj routes the swallowed rejection to a
set `:error-handler`; cljw drops without synthesizing one — no-handler case is
identical). All 8 e2e clj-oracle-verified; smoke green.

## Perf campaign (PAUSED behind the active flag; not the current task)

`.dev/.perf_campaign_active` is SET but the loop is in the quality sweep, not perf.
If the user re-opens perf: the only remaining accessible lever is D-386(a) (inline
`stepOnce` SP-marshalling, a risky UAF-class cycle — fresh focus + the
`CLJW_GC_TORTURE_ALLOC` safety net); JIT D-133 is user-fenced. Full perf state:
ADR-0148 + `private/notes/9.2.S-perf-remeasure-2026-06-17.md`.

## Cold-start reading order (resume)

handover → `.dev/project_facts.md` (F-002 / F-010 / F-011) → ROADMAP §9.0 (gap
areas I/II/III) → `.dev/accepted_divergences.yaml` (AD-001…046) → `.dev/debt.yaml`
(clj-parity residuals: D-458 cl-format V/#, D-446 multidim aget, D-463 per-var
events, D-431 Java per-class completeness — all barrier-none). memory
`direct-explore-fork-mechanical` + `clj_diff_sweep_methodology`.

