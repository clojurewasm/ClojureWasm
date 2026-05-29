# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `7b104659`+ (row 14.13 compat_tiers done; a bench-
  accumulation commit may sit on top — see `git log` for exact HEAD).
- **First commit on resume MUST be**: **row 14.13 deliverable (2) —
  `bench/history.yaml` v0.1.0 lock-point.** Run `PHASE_NAME=v0.1.0
  bash bench/quick.sh` (ReleaseFast; appends medians to
  `quick_baseline.txt`), then `bash bench/record.sh --id=14A.0
  --reason="Phase 14 row 14.13 — v0.1.0 lock-point baseline (Mac
  aarch64 ReleaseFast tree_walk)"` (reads the latest quick_baseline
  block, appends an ADR-0044 `lock: true` entry to `history.yaml`).
  Commit history.yaml. THEN deliverable (3) `cljw.error/with-context`.
- **Forbidden this session**: re-opening row 14.13 slice (a)/(b)
  compat_tiers (DONE @7b104659 — D5 migration of 6 shipped host_classes
  + Matcher/Socket added + zip kept Tier A; gate green 103/103). Re-doing
  D-100 / lazy-seq (ADR-0054 complete). Widening wasm FFI / row 14.12
  (F-010 de-prioritised). Pulling the v0.1.0 tag (row 14.14) before
  14.13 (2)+(3) land. Down-tiering zip to B (decided: stays A).

## Current state

Phase 14 v0.1.0 IN-PROGRESS. Mac gate **103/103** green (on-disk log
@7b104659). Row 14.13 progress: slice (a)/(b) **compat_tiers
reconciliation DONE @7b104659** — shipped host_classes migrated to
ADR-0029 D5 (Pattern/BigDecimal full; LocalDateTime/Duration/
ZonedDateTime/MessageDigest/Socket reservation w/ `status:` field;
Matcher added), `clojure.zip` stays Tier A (comprehensive impl,
e2e-tested), G3 --gate passes (14 D5 keyword entries). `cljw build`
ships end-to-end (D-100 discharged). ADR-0054 lazy-seq Layer-2 complete.

## Active task

**Row 14.13 — v0.1.0 polish bundle (2 deliverables remain).**

- **(2) `bench/history.yaml` v0.1.0 lock-point** (ADR-0044). Infra
  verified present: `bench/quick.sh` (ReleaseFast build, appends
  `quick_baseline.txt`), `bench/record.sh --id=… --reason=… [--backend=]`
  (reads latest quick_baseline block → appends `lock: true` entry to
  `history.yaml`; needs `yq`). Machine id auto = `mac-arm-m4pro`.
- **(3) `cljw.error/with-context` macro** (v5 §13.6 + ADR-0034 L172/
  L516). Spec: `(cljw.error/with-context {:request-id … :trace-id …}
  body)` — a dynamic var stacks context, merged as top-level fields when
  an error event is emitted (`src/app/error_render.zig`). **Verify
  prerequisite first**: the dynamic-binding runtime EXISTS in
  `src/runtime/env.zig` (`BindingFrame` threadlocal stack +
  `VarFlags.dynamic` + `Var.deref` walk), but `binding` is NOT yet a
  wired special form (analyzer `bindings.zig` handles only `let*`/
  `loop*`; no `(binding …)` / `^:dynamic` in the `.clj` corpus). So (3)
  likely needs a prerequisite: wire the `binding` special form +
  `^:dynamic` def-meta → frame push/pop (may be ADR-level — DA fork).
  New ns lives at `src/lang/clj/cljw/error.clj` + a `@embedFile` row in
  `src/lang/bootstrap.zig` (no `src/lang/clj/cljw/` dir exists yet).

## Open debts (named; full rows in `.dev/debt.md`)

- **D-119** `cljw` man-page rendering (opportunistic; no Clojure surface
  depends on it). **D-139** AOT fns drop param-name labels in error
  frames. **D-140** `cljw` startup reads whole self-exe for trailer.
- **D-105** time backing impls (LocalDateTime/Duration/ZonedDateTime).
  **D-106** net+crypto backing (Socket/MessageDigest). These are the
  reservations the compat_tiers D5 `status:` fields point at.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ ROADMAP §9.16 row 14.13 → `bench/{quick,record}.sh` + ADR-0044 →
v5 §13.6 (`private/notes/clj_vs_zig_split_proposal_v5.md`) +
`src/runtime/env.zig` (dynamic var runtime).
