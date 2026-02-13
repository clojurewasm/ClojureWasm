# Non-Functional Baselines

Measured on: 2026-02-13
Platform: macOS ARM64 (Apple M4 Pro), Zig 0.15.2
Binary: ReleaseSafe

## Thresholds

Exceeding ANY threshold is a **hard block** — do NOT commit.
Fix the regression first. No exceptions without explicit user approval.

| Metric              | Baseline   | Threshold  | Margin | How to measure                              |
|---------------------|------------|------------|--------|---------------------------------------------|
| Binary size         | 3.65 MB    | 4.0 MB     | +10%   | `stat -f%z zig-out/bin/cljw` (after ReleaseSafe build) |
| Startup time        | 4.0 ms     | 5 ms       | 1.25x  | `hyperfine -N --warmup 3 --runs 5 './zig-out/bin/cljw -e nil'` |
| RSS (light)         | 11.4 MB    | 12 MB      | +5%    | `/usr/bin/time -l ./zig-out/bin/cljw -e nil 2>&1 \| grep 'maximum resident'` |
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

## Benchmark Baselines (2026-02-13, single run)

| Benchmark              | Time (ms) | Ceiling (ms) |
|------------------------|-----------|--------------|
| fib_recursive          | 18        | 22           |
| fib_loop               | 9         | 11           |
| tak                    | 14        | 17           |
| arith_loop             | 10        | 12           |
| map_filter_reduce      | 14        | 17           |
| vector_ops             | 12        | 14           |
| map_ops                | 15        | 18           |
| list_build             | 11        | 13           |
| sieve                  | 13        | 16           |
| nqueens                | 19        | 23           |
| atom_swap              | 11        | 13           |
| gc_stress              | 33        | 40           |
| lazy_chain             | 13        | 16           |
| transduce              | 12        | 14           |
| keyword_lookup         | 15        | 18           |
| protocol_dispatch      | 11        | 13           |
| nested_update          | 15        | 18           |
| string_ops             | 27        | 32           |
| multimethod_dispatch   | 11        | 13           |
| real_workload          | 13        | 16           |

Wasm benchmarks excluded from regression gate (higher variance, dominated by zwasm).

## Updating Baselines

Baselines improve (get faster/smaller) → update freely after measurement.
Baselines worsen → requires explicit user approval with justification.
