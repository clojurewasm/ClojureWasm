# Non-Functional Baselines

Measured on: 2026-02-19 (post-zwasm v1.1.0)
Platform: macOS ARM64 (Apple M4 Pro), Zig 0.15.2
Binary: ReleaseSafe

## Thresholds

Exceeding ANY threshold is a **hard block** — do NOT commit.
Fix the regression first. No exceptions without explicit user approval.

| Metric              | Baseline   | Threshold  | Margin | How to measure                              |
|---------------------|------------|------------|--------|---------------------------------------------|
| Binary size         | 4.07 MB    | 4.3 MB     | +5%    | `stat -f%z zig-out/bin/cljw` (after ReleaseSafe build) |
| Startup time        | 4.8 ms     | 6 ms       | 1.25x  | `hyperfine -N --warmup 5 --runs 10 './zig-out/bin/cljw -e nil'` |
| RSS (light)         | 8.0 MB     | 12 MB      | +50%   | `/usr/bin/time -l ./zig-out/bin/cljw -e nil 2>&1 \| grep 'maximum resident'` |
| Benchmark (any)     | see below  | 1.2x       | +20%   | `bash bench/run_bench.sh --quick` |

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
