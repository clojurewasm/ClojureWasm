# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main`, gate GREEN (315/0, full gate 2026-06-11 07:31). All work on
  `main`; commit + `git push origin main` is the atomic Step 6 (`--force*`
  deny-listed). Gate cadence ADR-0107: per-commit smoke (background), batch the
  full gate ALONE at the ≤5 ceiling / boundary. **Perf measured ONLY on a
  Release binary** (`scripts/perf.sh` / `bench/`), never `time zig-out/bin/cljw`
  (Debug) — `.claude/rules/perf_measure_release.md`.

- **First commit on resume MUST be: the cljw-vs-v0 PERF-PARITY campaign — get
  cljw cold-start to BEAT Python across `bench/`, then keep going. User-directed
  2026-06-11: NOT ROI-gated — optimize relentlessly until Python is beaten;
  reviving deferred/abandoned optimizations (D-133 JIT / superinstruction) is
  expected.** Autonomous; only an explicit user stop halts it.

  **Why**: cw v0 beat Python **17/20** (`~/Documents/MyProducts/ClojureWasm/bench/README.md`);
  the from-scratch rewrite REGRESSED ~4× (it deferred v0's VM optimizations).
  Cold-start ms — v0 → current → Python:
  - arith_loop **5 → 170 → 53.8** (34× regression — the worst)
  - fib_recursive 16 → 67 → 20.8; map_filter_reduce 6 → 27 → 16.4;
    nested_update 12 → 56 → 15.3; lazy_chain 7 → 28 → 19.6; sieve 9 → 35 → 15.
  - current ALREADY beats Python on fib_loop / map_ops / list_build /
    atom_swap / multimethod_dispatch / vector_ops.
  v0's edge = `src/engine/vm/jit.zig` (ARM64/x86_64 hot-loop JIT, D87) +
  superinstructions (commits 37.2 / 37.3) — exactly the D-133 work the
  from-scratch parked (F-010).

  **Step 1 — mine v0 BEFORE experimenting** (user-directed: cheaper than v1
  trial-and-error + revert). **Start from [`.dev/perf_v0_baseline.md`](./perf_v0_baseline.md)**
  — already mines v0's `bench/history.yaml` + `git log` into: the v0→v1→Python
  gap, the table of WHICH v0 opts moved the needle (24A.9 arith-fastpath+IReduce
  → fib; 24C.7 filter-chain-collapse → sieve; **37.2/37.3 superinstructions**;
  **37.4 JIT → arith 31→3 ms**), the F121 benchmark-equivalence finding, and the
  JIT cross-platform/consolidation constraints. Then read the v0 artifacts it
  cites and prioritise the biggest measured gains.

  **Step 2 — benchmark-equivalence audit (配線 / 参照チェーン).** Verify each
  slow bench's per-language sources do EQUIVALENT work (no language handicapped
  or given a leg-up — check e.g. C constant-folding) and that cljw's `bench.clj`
  matches v0's (same N / algorithm). Trace the cljw interpreter hot-path
  reference/dispatch chain for arith_loop / fib / nested_update to localise the
  per-element overhead. **NO cheating — honest equivalent benchmarks only.**

  **Step 3 — optimize relentlessly.** Re-derive v0's proven wins cljw-clean
  (F-004; no verbatim copy per `no_copy_from_v1.md`); revive D-133. Likely order:
  superinstructions first (37.2/37.3 — pure bytecode, cross-platform-safe), then
  the **hot-loop JIT** for the last-mile arith win. **JIT (user-directed): must
  be correct on BOTH mac (ARM64) AND ubuntu (x86_64) from day one, and
  non-ad-hoc — decide the LAYER via an ADR before any codegen** (details +
  v0's JIT-bug precedents in `perf_v0_baseline.md` § JIT constraints). Measure
  cold-start vs Python each round (`bench/compare_langs.sh --cold`, µs; cljw-only
  A/B `bash bench/run_bench.sh --quick --bench=<name>`). Each opt: `// PERF:`
  marker + O-NNN ledger row + clj corpus (F-011) + **GC-torture safety** (the
  O-005/O-013 reverts below — any interpreter-frame / dispatch change MUST hold
  under `CLJW_GC_TORTURE` + deep recursion). Big surgery welcome (F-002); each
  unit its own revert-friendly commit.

- **Forbidden this session**: cheating the benchmarks (handicapping other
  languages or any arbitrary manipulation to fake a cljw win — honest
  equivalence only); editing zwasm; `git push --force*`.

## Just landed — perf + correctness 2026-06-11 (pushed to `main`)

Algorithmic wins (O-NNN in `.dev/optimizations.md`, each clj-corpus-verified):
O-009 `reductions` O(n²)→O(n) (2500×); O-011 map/keep-indexed O(n²)→O(n) (230×);
O-012 `string/join` O(n²)→O(n) (45×); O-007 native `sort`; O-010 native
`sort-by` (79×); O-008 release strip (3.39 MB). Correctness: `json/write-str` +
`clojure.walk` now handle hash_map/sorted_map (>8 keys) via new
`map.forEachEntry` / `sorted.forEachEntry`. Bench: cross-lang table → cold-start-
only µs + full machine spec (0dd36f50).
- **Reverted (correctness > perf, regression tests added)**: O-005 frame
  nil-init (VM roots the whole `callMethodImpl` locals slice → `undefined` tail
  traced under torture → SIGSEGV); O-013 concat right-nest (stack-overflowed
  `interleave`). **These are the cautionary precedents for Step 3.**

## Cold-start reading order (v0-parity perf campaign)

handover → **[`.dev/perf_v0_baseline.md`](./perf_v0_baseline.md)** (pre-mined:
the gap + which v0 opts worked + F121 equivalence + JIT constraints) → the v0
artifacts it cites (v0 `bench/history.yaml`, `.dev/optimizations.md`,
`ARCHITECTURE.md`, `src/engine/{vm/jit.zig,vm/vm.zig,compiler/}` — re-derive per
F-004) → cljw `.dev/optimizations.md` (O-NNN, incl O-005/O-013 GC lessons) +
`.dev/debt.yaml` D-133.
