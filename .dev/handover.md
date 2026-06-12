# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT; ≈ 16087139). All work on `main`;
  commit + `git push origin main` is the atomic Step 6 (`--force*` deny-listed).
  Gate cadence ADR-0107: per-commit smoke (background), batch the full gate ALONE
  at the ≤5 ceiling / boundary. **The full gate is now ~2 min (D-385 root-caused
  + fixed, ADR-0132) and builds `-Dwasm` throughout (ADR-0133)** — the prior
  multi-hour/timeout friction is gone. **Perf measured ONLY on a Release binary**
  (`bench/run_bench.sh --quick` / `scripts/perf.sh`), never `time zig-out/bin/cljw`
  (Debug) — `.claude/rules/perf_measure_release.md`.

- **First commit on resume MUST be: one of the 2 remaining cold-losers** — regex_count
  (45 vs 24.8, 1.8× — the WORST) or sieve (28 vs 20, 1.4×). Both are STRUCTURAL levers
  (not the alloc/variadic quick-wins already done): regex needs a simple-pattern
  matcher fast-path (literal / char-class loop, skipping the Pike-VM per-position
  setup — `runtime/regex/match.zig`); sieve needs the nested-filter-chain collapse
  (intricate — interleaved `rest`s, `core.clj` filter). NOT ROI-gated; fast-mode in
  `.dev/perf_campaign_essence.md`. Autonomous; only an explicit user stop halts.

  **Current standing (cljw vs Python COLD ms, 2026-06-11 — authoritative
  `compare_langs --lang=cw,py`)**: cljw WINS/parity on the vast majority (its ~ms
  startup beats Python's ~30ms on every startup-light bench). Beats/parity: fib 26≈24,
  tak (WIN), arith_loop (WIN), **mfr 15<16 (WIN)**, nested_update 25 vs 20 (1.22×),
  gc_stress 32 vs 30 (1.07×), bigint/lazy_chain (~parity). LOSE: **regex_count 45 vs
  24.8 (1.8×)**, **sieve 28 vs 20 (1.4×)** — the 2 structural levers above.

  **Landed this session (12 perf wins O-016..027, all `main`, diff-oracle + (for
  GC/frame) torture-validated; ubuntunote 311/0 through O-026)**: ADR-0131 in-VM frame
  stack (2a/2b — do NOT re-do); **D-386 DISPATCH ARC** (O-017 inline, O-018
  `op_*_local_const`, O-019 `op_*_locals`, O-021 `op_branch_*`, O-022 `op_recur_loop`)
  → fib/tak/arith_loop beat/match Python; **O-023 fused-reduce** (mfr 27→15, beats
  Python — LazySeq `fuse` slot + `-fused-reduce` over the existing transduce engine);
  **O-024** regex one-alloc tuple + ThreadList reuse (regex 55→45); **O-025** update-in
  indexed (27→25); **O-026** one-alloc array-map literal (gc_stress 41→32); **O-027**
  not= 2-arg arity (sieve 32→28); + the velocity MECHANIZATION + the v0 deep survey +
  the **full 38-bench sweep** (`9.2.S-v0-perf-deep-survey.md §10` — the real cold-losers
  are compute-heavy, NOT the startup-light benches).

  **Next levers** (after regex/sieve): JIT (v0 37.4, cross-platform required) for the
  last mile toward v0's numbers; a Zig update-in builtin (GC-careful) to fully close
  nested_update. The alloc/variadic quick-wins are exhausted.

  **OWED**: nothing outstanding — ubuntunote ran **314/0 green at HEAD** (`16087139`,
  incl. wasm + agent e2e); the local full gate no longer times out (D-385 fixed,
  ~2 min). Run a quick `bench/run_bench.sh --quick` before resuming perf work.

  **Measurement cadence (keep iteration fast)**: per iteration a FOCUSED quick bench
  only (`bash bench/run_bench.sh --quick --bench=<name>`); do NOT full-bench or
  compare to Python every round; commit on ONE smoke (ADR-0107, ≤5 ride);
  spot-check the impact area (changed e2e smoke + clj corpus + `CLJW_GC_TORTURE` on
  any dispatch/frame change — the O-005/O-013 reverts), not a full gate; batch the
  full gate + full + cross-lang bench + markdown refresh only when wins solidify.
  Each opt: `// PERF:` marker + O-NNN row (`.dev/optimizations.md`) + clj corpus
  (F-011). Big surgery welcome (F-002); each unit its own revert-friendly commit.

- **Forbidden this session**: cheating the benchmarks (handicapping other languages
  / any manipulation to fake a cljw win — honest equivalence only, already audited
  PASS); editing zwasm; `git push --force*`.

## Just landed — gate root-caused + wasm in default gate (2026-06-12, on `main`)

- **D-385 gate root-cause FIXED (ADR-0132)**: the "multi-hour gate" was the e2e
  running a **Debug** cljw (~1.7s cold-start × ~3200 spawns) — a bare `zig build`
  in `run_tier_a.sh` + a resume-skipped `build_cljw` reverted the shared binary.
  Full gate now **~113-190s**. `cljw --version` bakes in the build mode (semantic
  guard, not a size heuristic).
- **Wasm in the DEFAULT full gate (F-001 amended → ADR-0133)**: every executing
  gate `zig build` carries `-Dwasm`; `phase16_wasm_{ffi,run}` are gate steps;
  zwasm via the build.zig.zon tag-pin (no sibling). Verified GREEN on Mac +
  **ubuntunote 314/0**. The phase4 reversion (non-wasm rebuild) was the bug.
- **D-388 agent nested-send**: clj-faithful deferral (`releasePendingSends`,
  `nested_pending` threadlocal, GC-pinned) + deterministic two-await test.
  Residual single-await timing (eager-drainer vs clj pool) tracked in D-388.

## Cold-start reading order (resume)

handover → **`.dev/decisions/0131_in_vm_call_frame_stack.md`** (the lever's full
design + DA alternatives) → `private/notes/9.2.S-flat-frame-survey.md` (§ EMPIRICAL
UPDATE: Design 2 null + the profile) → `.dev/perf_v0_baseline.md` (§ Call-path
lever + Measurement cadence + v0 catalog) → `.dev/optimizations.md` (O-NNN incl
O-005/O-014/O-015) → `.dev/debt.yaml` (D-385 gate, D-133 JIT). v0 ref:
`~/Documents/MyProducts/ClojureWasm/` (re-derive per F-004, never copy).
