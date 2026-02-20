# Non-Functional Baselines

Measured on: 2026-02-19 (post-Phase 79A lazy bootstrap)
Platform: macOS ARM64 (Apple M4 Pro), Zig 0.15.2
Binary: ReleaseSafe

## Profiles

| Profile | Binary | Startup | RSS | Notes |
|---------|--------|---------|-----|-------|
| wasm=true (default) | 4.25MB | 4.6ms | 7.4MB | Full feature set |
| wasm=false | 3.68MB | 4.3ms | 7.4MB | No zwasm dependency |

## Thresholds

**Migration period (Phase 88A-88E)**: Binary size threshold is SUSPENDED.
Macro-to-Zig migration naturally increases binary size; will re-baseline after migration.
All other thresholds (startup, RSS, benchmarks) remain active.

| Metric              | Baseline   | Threshold  | Margin | How to measure                              |
|---------------------|------------|------------|--------|---------------------------------------------|
| Binary size         | 4.25 MB    | 4.5 MB     | +5%    | `stat -f%z zig-out/bin/cljw` (after ReleaseSafe build) |
| Startup time        | 4.6 ms     | 6.0 ms     | 1.3x   | `hyperfine -N --warmup 5 --runs 10 './zig-out/bin/cljw -e nil'` |
| RSS (light)         | 7.4 MB     | 10 MB      | +35%   | `/usr/bin/time -l ./zig-out/bin/cljw -e nil 2>&1 \| grep 'maximum resident'` |
| Benchmark (any)     | see below  | 1.2x       | +20%   | `bash bench/run_bench.sh --quick` |

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

## Benchmark Baselines (2026-02-18, zwasm v1.1.0, hyperfine 5 runs)

Source: `bench/history.yaml` entry `zwasm-v1.1.0` (commit 518fef2).

| Benchmark              | Time (ms) | Ceiling (ms) |
|------------------------|-----------|--------------|
| fib_recursive          | 17        | 20           |
| fib_loop               | 4         | 5            |
| tak                    | 7         | 8            |
| arith_loop             | 5         | 6            |
| map_filter_reduce      | 6         | 7            |
| vector_ops             | 5         | 6            |
| map_ops                | 4         | 5            |
| list_build             | 6         | 7            |
| sieve                  | 6         | 7            |
| nqueens                | 17        | 20           |
| atom_swap              | 6         | 7            |
| gc_stress              | 29        | 35           |
| lazy_chain             | 7         | 8            |
| transduce              | 6         | 7            |
| keyword_lookup         | 13        | 16           |
| protocol_dispatch      | 6         | 7            |
| nested_update          | 12        | 14           |
| string_ops             | 28        | 34           |
| multimethod_dispatch   | 6         | 7            |
| real_workload          | 10        | 12           |

Wasm benchmarks excluded from regression gate (higher variance, dominated by zwasm).

## Updating Baselines

Baselines improve (get faster/smaller) → update freely after measurement.
Baselines worsen → requires explicit user approval with justification.
