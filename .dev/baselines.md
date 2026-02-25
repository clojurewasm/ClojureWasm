# Non-Functional Baselines

Measured on: 2026-02-25 (v0.4.0 + GPA leak fix + JIT register fix)
Platform: macOS ARM64 (Apple M4 Pro), Zig 0.15.2
Binary: ReleaseSafe

## Profiles

| Profile | Binary | Startup | RSS | Notes |
|---------|--------|---------|-----|-------|
| wasm=true (default) | 4.76MB | 4.5ms | 7.9MB | Full feature set |
| wasm=false | (not measured) | — | — | No zwasm dependency |

## Thresholds

All-Zig migration complete (Phases A-F, C.1). Binary size threshold RESTORED.
Binary grew ~0.5MB due to embedded Clojure multiline strings (pprint, spec.alpha).
Phase E optimization target: reduce back toward 4.3MB.

| Metric              | Baseline   | Threshold  | Margin | How to measure                              |
|---------------------|------------|------------|--------|---------------------------------------------|
| Binary size         | 4.76 MB    | 5.0 MB     | +5%    | `ls -la zig-out/bin/cljw` (after ReleaseSafe build) |
| Startup time        | 4.5 ms     | 6.0 ms     | 1.3x   | `hyperfine -N --warmup 5 --runs 10 './zig-out/bin/cljw -e nil'` |
| RSS (light)         | 7.9 MB     | 10 MB      | +27%   | `/usr/bin/time -l ./zig-out/bin/cljw -e nil 2>&1 \| grep 'maximum resident'` |
| Benchmark (any)     | see below  | 1.2x       | +20%   | Per-benchmark: `bash bench/run_bench.sh --bench=NAME --runs=10 --warmup=5` |

## `cljw build` Artifact Baselines (2026-02-20)

Measured with `bash bench/build_bench.sh`. Test program: fib_recursive.

| Metric | Result | Notes |
|--------|--------|-------|
| Build time (`cljw build`) | 17.7ms | Source → single binary |
| Artifact size | 4.23MB | ≈ cljw binary + user source bytes |
| Artifact startup (fib) | 17.6ms | bootstrap + fib execution |
| Artifact vs direct execution | 1.00x | No overhead from embedding |
| Artifact startup (require pprint) | 6.4ms | Lazy bootstrap effective |

## Benchmark Regression Policy

**Performance must not regress.** The 1.2x margin exists only for measurement noise.

If any benchmark exceeds 1.2x baseline:
1. **Stop current task.** Do not commit the regressing change.
2. **Identify root cause.** Profile and find what slowed down.
3. **Fix in place** if the regression is a bug or unnecessary overhead.
4. **Insert optimization phase** if the regression is inherent to the new feature.
   Optimize first, then resume the original task.
5. Only proceed when ALL benchmarks are back within 1.2x.

Never accept "this feature needs to be slower" — find a way to keep it fast.

## Benchmark Baselines (2026-02-25, individual 10 runs + 5 warmup)

Source: `bench/history.yaml` entry `v0.4.0-fix`.

| Benchmark              | Time (ms) | Ceiling (ms) |
|------------------------|-----------|--------------|
| fib_recursive          | 17        | 20           |
| fib_loop               | 4         | 5            |
| tak                    | 8         | 10           |
| arith_loop             | 5         | 6            |
| map_filter_reduce      | 7         | 8            |
| vector_ops             | 7         | 8            |
| map_ops                | 6         | 7            |
| list_build             | 6         | 7            |
| sieve                  | 6         | 7            |
| nqueens                | 14        | 17           |
| atom_swap              | 6         | 7            |
| gc_stress              | 32        | 38           |
| lazy_chain             | 6         | 7            |
| transduce              | 7         | 8            |
| keyword_lookup         | 13        | 16           |
| protocol_dispatch      | 5         | 6            |
| nested_update          | 10        | 12           |
| string_ops             | 27        | 32           |
| multimethod_dispatch   | 6         | 7            |
| real_workload          | 12        | 14           |

Wasm benchmarks excluded from regression gate (higher variance, dominated by zwasm).

## Measurement Methodology

**Baselines must be measured per-benchmark individually** to avoid thermal throttling.
Sequential full-suite runs (`run_bench.sh` without `--bench`) are for quick regression
screening only — do NOT use them to establish or update baselines.

For baseline establishment or suspected regression investigation:
```bash
# Per-benchmark, 10 runs + 5 warmup (accurate)
bash bench/run_bench.sh --bench=NAME --runs=10 --warmup=5

# Or direct hyperfine for raw data with σ
hyperfine -N --warmup 5 --runs 10 './zig-out/bin/cljw bench/benchmarks/NN_NAME/bench.clj'
```

For commit gate regression screening:
```bash
# Quick sequential check (3 runs + 1 warmup) — OK for detecting gross regressions
bash bench/run_bench.sh
```

**Key insight**: In the 4-10ms range, 1-2ms of noise is 20-50% variance. 5 runs is
insufficient — use 10+ runs for baselines. The 1.2x ceiling accounts for normal
measurement noise, not for inaccurate baselines.

## Updating Baselines

Baselines improve (get faster/smaller) → update freely after measurement.
Baselines worsen → requires explicit user approval with justification.
