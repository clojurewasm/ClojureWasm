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

- **First commit on resume MUST be: continue the cljw-vs-Python PERF campaign at
  the next lever — the FLAT-FRAME call-dispatch** (the call-bound residue). The
  campaign is well underway and NOT ROI-gated (optimize relentlessly until cljw
  beats Python across `bench/`); user-directed 2026-06-11. Autonomous; only an
  explicit user stop halts it.

  **State**: cljw now beats Python **12/23** cross-lang (was ~6/19 pre-campaign).
  Landed: ADR-0130 arith intrinsic family (O-014: arith_loop 170→107 ms 37%, fib
  71→61) + exact-count frame rooting (O-015: fib 61→58, GC-torture-verified — the
  O-005 redo done right). Steps 1-2 of the original plan (mine v0 / equivalence
  audit = PASS, benches are fair) are DONE — do NOT re-do them.

  **Behind Python (the targets), cold µs cljw vs py**: fib_recursive 58 vs 24
  (2.4×) + nested_update 64 vs 20 (3.1×) are **call-bound** → the flat-frame lever.
  arith_loop 119 vs 58, sieve 39 vs 20, regex 53 vs 24, map_filter_reduce, gc_stress
  are **algorithmic/alloc** → v0's 24C wins. Already winning: fib_loop/tak/vector_ops/
  map_ops/list_build/atom_swap/lazy_chain/transduce/keyword_lookup/protocol/multimethod/sort.

  **Next lever — flat-frame call-dispatch** (survey: `private/notes/9.2.S-flat-frame-survey.md`,
  persists across /clear on disk). fib/tak are call-bound: a 6-hop host-C-stack
  recursion (`op_call → vt.callFn → treeWalkCall → callFunction → callMethodImpl →
  vt.evalChunk → vm.eval`) with 2 vtable indirections. The monomorphic IC is a red
  herring (v1 already has `CallSite.lookupWithCache`; fib uses plain `.fn_val`).
  **Smallest first slice = Design 2**: a vm-local fast path for a 2-`.fn_val` call
  that skips the treeWalkCall switch + double vtable hop (A1 GC root shape UNCHANGED
  → not the O-005 UAF class; correctness net = the diff oracle). Replicate, don't
  skip, the trace (ADR-0119) + env (ADR-0129) + recur. Full = Design 1 (in-VM call
  frame: also fixes deep-recursion SIGSEGV; A1 re-root = GC-critical, needs an ADR +
  CLJW_GC_TORTURE). Intricate — give it fresh focus.

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

## Just landed — perf campaign 2026-06-11 (pushed to `main`)

O-014 arith intrinsic family (op_add/sub/mul/lt/le/gt/ge/eq; ADR-0130) + O-015
exact-count frame rooting → cljw 12/23 vs Python. cross-lang re-recorded
(cold-only µs, full machine spec); D-385 added gate `total wall + slowest-N`
timing (showed zig build test ×2 = 67 s, corpus_regression = 25 s dominate — the
gate is process-spawn-bound). Earlier batch (O-007…O-013): native sort/sort-by,
reductions/map-indexed/string-join O(n²)→O(n), strip; json/walk hash_map fixes.
- **Cautionary precedents for any dispatch/frame change**: O-005 (frame nil-init
  left rooting at full 256 → traced undefined tail → UAF) + O-013 (concat
  right-nest → interleave stack overflow). Both reverted; both have regression tests.

## Cold-start reading order (resume)

handover → `private/notes/9.2.S-campaign-milestone.md` (this batch's summary +
next-lever map) → `private/notes/9.2.S-flat-frame-survey.md` (the next lever's
plan) → `.dev/perf_v0_baseline.md` (§ Call-path lever + § Measurement cadence +
the v0 catalog) → `.dev/optimizations.md` (O-NNN incl O-005/O-014/O-015) →
`.dev/debt.yaml` (D-385 gate efficiency, D-133 JIT). v0 ref:
`~/Documents/MyProducts/ClojureWasm/` (re-derive per F-004, never copy).
