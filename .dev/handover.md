# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT; ≈ f35784ba). All work on `main`;
  commit + `git push origin main` is the atomic Step 6 (`--force*` deny-listed).
  Gate cadence ADR-0107: per-commit smoke (background), batch the full gate ALONE
  at the ≤5 ceiling / boundary. **Perf measured ONLY on a Release binary**
  (`bench/run_bench.sh --quick` / `scripts/perf.sh`), never `time zig-out/bin/cljw`
  (Debug) — `.claude/rules/perf_measure_release.md`.

- **First commit on resume MUST be: implement ADR-0131 increment 1 — the in-VM
  call-frame stack RESTRUCTURE-ONLY step** (the flat-frame call-dispatch lever).
  The campaign is NOT ROI-gated (optimize relentlessly until cljw beats Python
  across `bench/`); user-directed 2026-06-11. Autonomous; only an explicit user
  stop halts it.

  **State**: cljw beats Python **12/23** cross-lang. Landed: O-014 arith intrinsics
  + O-015 frame rooting; **`bindCallFrame` extraction `ab1959c2`** (the shared
  single-source binder ADR-0131 reuses). Steps 1-2 of the original plan (mine v0 /
  equivalence audit = PASS) are DONE — do NOT re-do them.

  **The flat-frame lever is settled (ADR-0131, Accepted, Alt A).** Design 2 (a
  monomorphic op_call fast path calling eval() inline) was prototyped + measured
  this cycle: fib 57→56, tak 18 — **NO win**, reverted as excessive-skeleton. A
  `sample` profile of `(fib 35)` proved why: 100% in a 5-host-frame recursion
  cycle, no GC/alloc — the tax is the **non-tail `eval` re-entry per call**, which
  only flattening removes. ADR-0131 decision = **Alt A**: flatten op_call to push
  an in-VM frame + continue ONE eval loop, PRESERVING v1's locals/operand split
  (= the F-011 `bindCallFrame` seam; Alt B's v0 unification was rejected for
  forking that binder). Devil's-advocate corrections folded in: NO `saved_ns`
  (v1 doesn't switch ns per call), per-`eval` handler stacks scope reentry for
  free, window `loc_stack`, and **the torture e2e MUST allocate per frame** (fib
  allocates nothing → proves no rooting). 2 increments: (1) frame array + struct,
  top-level runs `frame_count==1`, behaviour-identical, A1 reshape under torture;
  (2) op_call push / op_ret pop / frame-aware throw-unwind / deep-recursion cap.
  Read ADR-0131 + the survey's EMPIRICAL UPDATE before touching the eval loop.

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

## Just landed — flat-frame lever settled 2026-06-11 (pushed to `main`)

`bindCallFrame` shared single-source binder extracted (`ab1959c2`); Design 2
measured null + reverted; **ADR-0131 (in-VM call-frame stack, Alt A) Accepted**
with a Devil's-advocate fork. Prior batch: O-014 arith intrinsics + O-015 frame
rooting → cljw 12/23 vs Python; D-385 gate timing.
- **Cautionary precedents for any dispatch/frame change**: O-005 (frame nil-init
  left rooting at full 256 → traced undefined tail → UAF) + O-013 (concat
  right-nest → interleave stack overflow). Both reverted; both have regression
  tests. ADR-0131's torture e2e MUST allocate per frame (fib proves no rooting).

## Cold-start reading order (resume)

handover → **`.dev/decisions/0131_in_vm_call_frame_stack.md`** (the lever's full
design + DA alternatives) → `private/notes/9.2.S-flat-frame-survey.md` (§ EMPIRICAL
UPDATE: Design 2 null + the profile) → `.dev/perf_v0_baseline.md` (§ Call-path
lever + Measurement cadence + v0 catalog) → `.dev/optimizations.md` (O-NNN incl
O-005/O-014/O-015) → `.dev/debt.yaml` (D-385 gate, D-133 JIT). v0 ref:
`~/Documents/MyProducts/ClojureWasm/` (re-derive per F-004, never copy).
