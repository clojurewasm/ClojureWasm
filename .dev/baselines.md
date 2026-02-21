# Non-Functional Baselines

Measured on: 2026-02-21 (post All-Zig Migration, Phase B.16 + C.1)
Platform: macOS ARM64 (Apple M4 Pro), Zig 0.15.2
Binary: ReleaseSafe

## Profiles

| Profile | Binary | Startup | RSS | Notes |
|---------|--------|---------|-----|-------|
| wasm=true (default) | 4.52MB | 4.2ms | 7.6MB | Full feature set |
| wasm=false | (not measured) | — | — | No zwasm dependency |

## Thresholds

All-Zig migration complete (Phases A-F, C.1). Binary size threshold RESTORED.
Binary grew ~0.5MB due to embedded Clojure multiline strings (pprint, spec.alpha).
Phase E optimization target: reduce back toward 4.3MB.

| Metric              | Baseline   | Threshold  | Margin | How to measure                              |
|---------------------|------------|------------|--------|---------------------------------------------|
| Binary size         | 4.52 MB    | 4.8 MB     | +6%    | `ls -la zig-out/bin/cljw` (after ReleaseSafe build) |
| Startup time        | 4.2 ms     | 6.0 ms     | 1.4x   | `hyperfine -N --warmup 5 --runs 10 './zig-out/bin/cljw -e nil'` |
| RSS (light)         | 7.6 MB     | 10 MB      | +32%   | `/usr/bin/time -l ./zig-out/bin/cljw -e nil 2>&1 \| grep 'maximum resident'` |
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

## Benchmark Baselines (2026-02-21, post All-Zig, hyperfine 5 runs)

Source: `bench/history.yaml` entry `B.16`.

| Benchmark              | Time (ms) | Ceiling (ms) |
|------------------------|-----------|--------------|
| fib_recursive          | 17        | 20           |
| fib_loop               | 4         | 5            |
| tak                    | 7         | 8            |
| arith_loop             | 4         | 5            |
| map_filter_reduce      | 6         | 7            |
| vector_ops             | 6         | 7            |
| map_ops                | 5         | 6            |
| list_build             | 7         | 8            |
| sieve                  | 6         | 7            |
| nqueens                | 15        | 18           |
| atom_swap              | 4         | 5            |
| gc_stress              | 30        | 36           |
| lazy_chain             | 7         | 8            |
| transduce              | 6         | 7            |
| keyword_lookup         | 12        | 14           |
| protocol_dispatch      | 4         | 5            |
| nested_update          | 10        | 12           |
| string_ops             | 26        | 31           |
| multimethod_dispatch   | 7         | 8            |
| real_workload          | 12        | 14           |

Wasm benchmarks excluded from regression gate (higher variance, dominated by zwasm).

## Updating Baselines

Baselines improve (get faster/smaller) → update freely after measurement.
Baselines worsen → requires explicit user approval with justification.
