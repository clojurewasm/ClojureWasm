# Perf v0-parity campaign — mined baseline (seed for the optimization campaign)

> Created 2026-06-11 (user-directed). The cljw-vs-v0 perf-parity campaign's
> data-driven starting point: WHICH optimizations made cw v0 fast, mined from
> v0's own `bench/history.yaml` + `git log`, so v1 re-implements proven winners
> instead of trial-and-error + revert. v0 clone:
> `~/Documents/MyProducts/ClojureWasm/`. Re-derive cljw-clean (F-004; NEVER
> verbatim-copy per `.claude/rules/no_copy_from_v1.md`).

## The gap (cold-start ms: v0 → current v1 → Python; lower better)

v0 beat Python **17/20**; current v1 lost most of that (it deferred v0's VM
optimizations — D-133). v1 is roughly at v0's *pre-24A* level.

| bench             | v0 final | v1 now | Python | note                     |
|-------------------|----------|--------|--------|--------------------------|
| arith_loop        | **4–5** | 170    | 53.8   | 34× regression — worst |
| fib_recursive     | 16       | 67     | 20.8   |                          |
| sieve             | 5–7     | 35     | 15.1   |                          |
| map_filter_reduce | 6        | 27     | 16.4   |                          |
| lazy_chain        | 5–7     | 28     | 19.6   |                          |
| nested_update     | 12       | 56     | 15.3   |                          |
| tak               | 8        | 20     | 15.4   |                          |

Already beating Python in v1: fib_loop / map_ops / list_build / atom_swap /
multimethod_dispatch / vector_ops.

## Which v0 optimizations moved the needle (from `bench/history.yaml`)

Each row = a v0 phase id + reason; arrows = the big measured drop it caused.
Read the matching v0 commit/phase, then re-derive in v1.

| v0 phase  | what                                               | measured drop                                     |
|-----------|----------------------------------------------------|---------------------------------------------------|
| 24A.3     | fused reduce + dispatch + stack array              | lazy_chain 21375→7356, mfr 4013→1287            |
| **24A.9** | **arith fast-path + IReduce**                      | **fib 502→28**                                   |
| 24C.1     | fix fused reduce (restore `__zig-lazy-map` meta)   | lazy_chain 6655→17, mfr 1293→179                |
| 24C.4     | vector geometric COW + collection ops              | mfr 179→14                                       |
| **24C.7** | **filter-chain collapsing + active VM call**       | **sieve 1698→16**                                |
| 27.3e     | NaN boxing (Value 48B→8B)                         | broad: lazy 16→9, mfr 17→10 — *v1 already has* |
| 32        | build-time bootstrap cache                         | lazy_chain 9→5 — *v1 already has (ADR-0056)*    |
| **37.2**  | **superinstructions (fuse common opcode seqs)**    | arith 53→40, fib 19→16                          |
| **37.3**  | **fused branch + loop superinstructions**          | arith 40→31                                      |
| **37.4**  | **JIT PoC — ARM64 hot-loop native codegen (D87)** | **arith 31→3**                                   |
| 83E-v2    | all-Zig macro migration                            | lazy_chain 6→2                                   |

So the lever order roughly: (1) arith/fib fast-paths + IReduce (24A.9),
(2) fused-reduce / filter-chain collapse for lazy/mfr/sieve (24A.3/24C.1/24C.7),
(3) **superinstructions** (37.2/37.3 — cross-platform-safe, no machine code),
(4) **hot-loop JIT** (37.4 — the last-mile arith 10×). v1 already has NaN-box +
AOT bootstrap, so skip those.

## Benchmark equivalence (v0 already audited this — F121)

`history.yaml` header documents F121 (2026-02-09): pre-F121 the OTHER languages
used easier algorithms, unfair to cljw — C used a plain array where cljw used a
hash map (map_ops), C/Py/Ruby/Zig/Java used standard Eratosthenes where cljw
used filter-based (sieve), C/Zig used struct field access (keyword_lookup),
Python used deque (list_build), etc. F121 made them EQUIVALENT. So v0's 17/20 is
post-equivalisation. **Audit task for v1: diff each `bench.{c,go,py,rb,js,java}`
against v0's post-F121 versions — confirm v1 did not regress the equivalence
(no language handed a leg-up). No cheating the other direction either.**

## JIT constraints (user-directed 2026-06-11) — before writing any codegen

- **Cross-platform from day one**: ARM64 (mac) AND x86_64 (ubuntu) both correct,
  no platform-specific bugs. v0 shipped JIT bugs it had to fix later —
  `b4c7077` "Fix JIT register clobbering: use only caller-saved registers",
  `6ce917a` "JIT arch guard + test path fix", `v0.4.0-fix` JIT register fix.
  Learn from those; gate both arches (ubuntunote for x86_64).
- **Non-ad-hoc / consolidated**: decide the LAYER first (an ADR) — where the JIT
  lives, its boundary with the VM, how hot paths are detected/dispatched — so it
  is one cohesive module, not scattered codegen. Likely under
  `src/eval/backend/` beside the VM. Superinstructions (37.2/37.3, pure
  bytecode, no machine code) are the lower-risk precursor and may get most of
  the win before the JIT is needed.
- Every step: F-011 (clj-equivalent, corpus) + **GC-torture safety** (the
  O-005/O-013 reverts — interpreter-frame / dispatch changes must hold under
  `CLJW_GC_TORTURE` + deep recursion).

## v0 artifacts to read (Step 1 of the campaign)

- `~/Documents/MyProducts/ClojureWasm/bench/history.yaml` — the full timing log.
- `…/.dev/optimizations.md` — v0's optimization catalog (what worked + why).
- `…/.dev/decisions.md` — D87 (JIT) and the VM-opt decisions.
- `…/ARCHITECTURE.md` — pipeline / Value repr / backends / GC / JIT layering.
- `…/src/engine/{vm/jit.zig, vm/vm.zig, compiler/, evaluator/tree_walk.zig}`.
- `…/git log` perf phases: 36.11 / 37.1 / 37.2 / 37.3 / 37.4 / Phase 37 / 79A.
