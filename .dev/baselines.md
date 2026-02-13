# Non-Functional Baselines

Measured on: 2026-02-14 (v0.2.0)
Platform: macOS ARM64 (Apple M4 Pro), Zig 0.15.2
Binary: ReleaseSafe

## Thresholds

Exceeding ANY threshold is a **hard block** — do NOT commit.
Fix the regression first. No exceptions without explicit user approval.

| Metric              | Baseline   | Threshold  | Margin | How to measure                              |
|---------------------|------------|------------|--------|---------------------------------------------|
| Binary size         | 3.90 MB    | 4.0 MB     | +3%    | `stat -f%z zig-out/bin/cljw` (after ReleaseSafe build) |
| Startup time        | 4.2 ms     | 5 ms       | 1.19x  | `hyperfine -N --warmup 3 --runs 5 './zig-out/bin/cljw -e nil'` |
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

## Benchmark Baselines (2026-02-14, v0.2.0, hyperfine 5 runs)

| Benchmark              | Time (ms) | Ceiling (ms) |
|------------------------|-----------|--------------|
| fib_recursive          | 18        | 22           |
| fib_loop               | 5         | 6            |
| tak                    | 8         | 10           |
| arith_loop             | 5         | 6            |
| map_filter_reduce      | 6         | 7            |
| vector_ops             | 6         | 7            |
| map_ops                | 5         | 6            |
| list_build             | 4         | 5            |
| sieve                  | 5         | 6            |
| nqueens                | 15        | 18           |
| atom_swap              | 5         | 6            |
| gc_stress              | 26        | 31           |
| lazy_chain             | 6         | 7            |
| transduce              | 7         | 8            |
| keyword_lookup         | 12        | 14           |
| protocol_dispatch      | 38        | 46           |
| nested_update          | 10        | 12           |
| string_ops             | 24        | 29           |
| multimethod_dispatch   | 5         | 6            |
| real_workload          | 10        | 12           |

Wasm benchmarks excluded from regression gate (higher variance, dominated by zwasm).

## Updating Baselines

Baselines improve (get faster/smaller) → update freely after measurement.
Baselines worsen → requires explicit user approval with justification.
