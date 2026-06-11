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

- **First commit on resume MUST be: implement ADR-0131 increment 2b — the FLATTEN**
  (op_call pushes an in-VM frame + continues ONE eval loop; op_ret pops). The
  campaign is NOT ROI-gated (optimize relentlessly until cljw beats Python across
  `bench/`); user-directed 2026-06-11. Autonomous; only an explicit user stop halts.

  **State**: cljw beats Python ≥12/23. Landed THIS campaign: O-014 arith + O-015
  frame rooting; `bindCallFrame` extraction (`ab1959c2`); ADR-0131 (Alt A, +DA);
  the `frame_local_alloc` allocating-per-frame torture gate (`13cefee8`); and
  **2a: the per-thread operand arena `VmArena` (`a12fdb09`, O-016) — fib 56→41 ms,
  tak 18→15** (an unexpected win; arena stays warm vs cold per-eval host arrays).
  The arena + its `op_top`-rooting are PROVEN under torture. Do NOT re-do 2a.

  **2b (the flatten — where the host `eval` re-entry, the real tax, is removed).**
  Settled design in **`.dev/decisions/0131…`** + the survey's `## CONVERGED
  INCREMENT-2a SPEC` + `## 2a LANDED` sections (read both). Plan: add
  `BytecodeChunk.has_handlers: bool` (compile-finalize). op_call flattens iff callee
  `.fn_val` + selectMethod hits a bytecode method + `!has_rest` + `!has_handlers`
  → `bindCallFrame` into a locals window in the arena + push a `CallFrame` +
  `continue`; op_ret pops; bounded throw-unwind (flattened frames are handler-free);
  deep recursion → catchable `StackOverflow` at the arena cap. Gates: the
  `frame_local_alloc` torture + diff oracle + **a new reduce-throw-outer-try diff
  case** (per-`eval` handler stacks scope reentry — the highest parity risk) +
  fib/tak quick bench (expect the drop toward v0's 16 ms). DA: NO `saved_ns`
  (v1 doesn't switch ns per call). Intricate + GC-critical — give it fresh focus.

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
