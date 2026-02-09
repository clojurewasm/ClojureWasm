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

| Benchmark      | .wasm source     | Parameters            | Expected |
|----------------|------------------|-----------------------|----------|
| wasm_fib       | fib.wasm         | fib(20) x 10000       | 6765     |
| wasm_sieve     | sieve.wasm       | sieve(65536) x 100    | 6542     |
| wasm_tak       | tak.wasm         | tak(18,12,6) x 10000  | 7        |
| wasm_arith     | arith.wasm       | loop 10M iterations   | 10000000 |

Each wasm benchmark is measured three ways:
1. **cw** — ClojureWasm wasm/load + wasm/fn + loop
2. **wasmtime** — `wasmtime run --invoke <fn> <args>` (process per invocation)
3. **wasmtime-aot** — pre-compiled with `wasmtime compile` (where applicable)

### Measurement script

`bench/wasm_bench.sh` — dedicated wasm benchmark runner.
Uses hyperfine. Outputs comparison table + YAML.

## Baseline (Phase 45.1, 2026-02-10)

TinyGo-compiled .wasm with built-in iteration loops (`result & 1` anti-optimization).
Measured via `wasm_bench.sh`, startup subtracted ("warm" values).

| Benchmark | CW warm (ms) | wasmtime warm (ms) | Ratio |
|-----------|-------------|-------------------|-------|
| fib(20)x10K | 10054 | 205 | 49x |
| tak(18,12,6)x10K | 27301 | 1148 | 24x |
| arith(1M)x10 | ~1 | ~1 | 1x |
| sieve(64K)x100 | 545 | 6 | 99x |

Key insights:
- **arith (tight integer loop)**: CW at parity — loop dispatch is already optimized
- **fib/tak (recursive calls)**: 24-49x — wasm function call overhead is the bottleneck
- **sieve (memory-heavy)**: 99x — memory load/store instructions are slow
- CW startup+load (3.3ms) is faster than wasmtime startup (5.0ms)

## Optimization Roadmap (from D90)

Priority order:

1. **Predecoded IR** — convert wasm bytecode to fixed-width 8-byte instructions
   at module load time. Eliminates LEB128 decode + bounds checks at dispatch.
   Expected: 40-60% dispatch improvement.

2. **Tail-call threaded dispatch** — replace switch(opcode) with function pointer
   table + `@call(.always_tail, ...)`. Eliminates branch misprediction.
   Expected: further 30-50% on top of predecoded IR.

3. **Superinstructions** — fuse common patterns (local.get + i32.add, etc.)
   into single dispatch entries. Same technique as Clojure VM Phase 37.2.

4. **Memory access optimization** — cache memory base pointer, avoid bounds
   check on every load/store where provably safe.

5. **Constant folding / dead code elimination** — at predecode time.

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
