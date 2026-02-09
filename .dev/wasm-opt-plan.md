# Wasm Runtime Optimization Plan (Phase 45)

Goal: bring ClojureWasm's Wasm interpreter performance to wasmtime-competitive levels.
This is a multi-session iterative effort. Each session picks up from the latest baseline.

## Iteration Loop

Every session follows this cycle:

```
1. Orient    — read this file + memo.md, check baseline numbers, git log
2. Benchmark — run full wasm benchmark suite, compare CW vs wasmtime
3. Profile   — identify the current top bottleneck
4. Optimize  — implement one focused optimization
5. Measure   — re-run wasm benchmarks, record in wasm_history.yaml
6. Regress   — run non-wasm benchmarks (run_bench.sh --quick) to check no regression
7. Commit    — one commit per optimization, update baseline in this file
8. Loop      — go to step 2 (or stop if session ending)
```

## Benchmark Suite

### Cross-language benchmarks (native execution)

TinyGo programs added as `bench.go` in all 20 existing benchmark directories (01-20).
compare_langs.sh supports `tgo` (TinyGo native) language.

These serve dual purpose: native performance comparison AND .wasm source for wasm benchmarks.

### Wasm FFI benchmarks (via ClojureWasm + wasmtime)

TinyGo-compiled .wasm files in `bench/wasm/`. These are realistic wasm modules
(with TinyGo runtime overhead: scheduler, allocator, WASI imports).

| Benchmark  | .wasm source | Parameters           | Expected |
|------------|--------------|----------------------|----------|
| wasm_fib   | fib.wasm     | fib(20) x 10000      | 6765     |
| wasm_sieve | sieve.wasm   | sieve(65536) x 100   | 6542     |
| wasm_tak   | tak.wasm     | tak(18,12,6) x 10000 | 7        |
| wasm_arith | arith.wasm   | loop 10M iterations  | 10000000 |

Each wasm benchmark is measured three ways:
1. **cw** — ClojureWasm wasm/load + wasm/fn + loop
2. **wasmtime** — `wasmtime run --invoke <fn> <args>` (process per invocation)
3. **wasmtime-aot** — pre-compiled with `wasmtime compile` (where applicable)

### Measurement script

`bench/wasm_bench.sh` — dedicated wasm benchmark runner.
Uses hyperfine. Outputs comparison table + YAML.

## Baseline (Phase 45.5, 2026-02-10)

After all Phase 45 optimizations: predecoded IR + superinstructions + cached memory.
All modules built with `-scheduler=none`. Measured via `wasm_bench.sh`, startup subtracted.

| Benchmark        | CW warm (ms) | wasmtime warm (ms) | Ratio | vs 45.1b |
|------------------|--------------|--------------------|-------|----------|
| fib(20)x10K      | 4387         | 225                | 19.5x | 2.30x    |
| tak(18,12,6)x10K | 14295        | 1217               | 11.8x | 1.91x    |
| arith(1M)x10     | 0.1          | 0.1                | 1.0x  | —        |
| sieve(64K)x100   | 198          | 6.6                | 30.1x | 3.03x    |
| fib_loop(25)x1M  | 176          | 2.7                | 65.1x | 2.28x    |
| gcd(1M,700K)x1M  | 311          | 44.3               | 7.0x  | 2.04x    |

Phase 45 cumulative improvements (vs 45.1b baseline):
- **fib 2.30x** (10070→4387ms): predecoded IR 1.77x + superinstructions 1.30x
- **tak 1.91x** (27320→14295ms): predecoded IR 1.68x + superinstructions 1.13x
- **sieve 3.03x** (600→198ms): predecoded IR 2.51x + superinstructions 1.18x + cached memory ~3%
- **gcd 2.04x** (633→311ms): predecoded IR 2.11x (superinstructions neutral for rem_s)
- **45.3 (tail-call dispatch) SKIPPED**: 0% improvement on Apple M4
- **45.5 (cached memory)**: marginal (~3% on sieve), kept for code quality
- Remaining gap to wasmtime: 7-65x (interpreter vs JIT fundamental limit)
- CW startup+load (3.7ms) still faster than wasmtime (5.2ms)

## Optimization Roadmap (from D90)

Priority order:

1. **Predecoded IR** — convert wasm bytecode to fixed-width 8-byte instructions
   at module load time. Eliminates LEB128 decode + bounds checks at dispatch.
   Expected: 40-60% dispatch improvement.

2. ~~**Tail-call threaded dispatch**~~ — SKIPPED (45.3). Tested iterative call
   elimination; 0% improvement on Apple M4. Branch prediction too effective.

3. **Superinstructions** — DONE (45.4). 11 fused opcodes (0xE0-0xEA).
   Peephole pass in predecode.zig fuses local.get+const/local+arith/cmp patterns.
   Results: fib 1.30x, tak 1.13x, sieve 1.18x.

4. **Memory access optimization** — DONE (45.5). Cached memory pointer in
   executeIR eliminates triple-indirection. Marginal improvement (~3% on sieve).

5. **Constant folding / dead code elimination** — deferred (low ROI for current benchmarks).

## Files

- Wasm runtime: `src/wasm/vm.zig` (3177 lines, 200+ opcodes)
- Wasm types: `src/wasm/types.zig`
- Wasm module: `src/wasm/module.zig`
- Wasm instance: `src/wasm/instance.zig`
- Wasm WASI: `src/wasm/wasi.zig`
- Wasm builtins: `src/wasm/builtins.zig` (Clojure FFI bridge)

## Decision Log

- D86: Wasm interpreter optimization (VM reuse, sidetable)
- D90: Predecoded IR + tail-call research results
- D92+: new decisions as optimizations proceed

## Session Handover

After each session, update:
1. Baseline numbers in this file
2. `.dev/memo.md` Current Task / Previous Task
3. `bench/wasm_history.yaml` with wasm benchmark results
4. `bench/history.yaml` via record.sh (if non-wasm benchmarks affected)

## Regression Guard

Wasm optimizations may touch core runtime code (`src/wasm/vm.zig`, `src/wasm/instance.zig`).
Always verify non-wasm benchmarks don't regress:
```bash
bash bench/run_bench.sh --quick   # Should match or beat previous baseline
```
