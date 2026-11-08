# FFI boundary cost probes

Isolates the cost of one `wasm/call` crossing from the loop and call overhead
around it. Run each under hyperfine, take the min, subtract:

    per crossing = (wasm_call - noop) / 1e6
    per clj call = (clj_call  - noop) / 1e6

`noop` is startup plus module load, so it is the right subtrahend for both.
`clj_call` is the same loop shape and arity with a Clojure callee, which is what
separates "the crossing is expensive" from "the loop is expensive".

    P="taskset -c 0-11"   # pin: a hybrid host otherwise measures core assignment
    hyperfine --warmup 3 --runs 15 -N \
      "$P ./zig-out/bin/cljw .dev/bench/ffi_boundary/noop.clj" \
      "$P ./zig-out/bin/cljw .dev/bench/ffi_boundary/clj_call.clj" \
      "$P ./zig-out/bin/cljw .dev/bench/ffi_boundary/wasm_call.clj"

## Measured 2026-09-05, Ultra 9 185H, ReleaseSafe -Dwasm, min-of-15

    Clojure fn call                   184 ns
    wasm/call :engine interp          392 ns    (2.1x a Clojure call)
    wasm/call :engine auto (JIT)   18,875 ns    (48x the interp path)

The 18.9 us is not the cost of crossing. It is zwasm/D-584: `computeStackLimit`
runs on every JIT invocation, and on Linux/glibc on the INITIAL thread glibc
answers by opening and parsing `/proc/self/maps`. Confirmed with zwasm's own
runner on this box (`zig build bench-latency`): `stack_limit_query_ns` 26,262
against `jit_ns` 27,436, so the query is ~96% of the per-call JIT cost. The
interpreter caches the same value, which is why it wins here.

Do not re-derive this from the source. An earlier pass read the call graph, found
`findExportFunc` re-parsing the module three times per call, and named that as
the cause. It is real (zwasm/D-585) but sits in the ~1.2 us remainder. See hive
memory 20260905010714-4c94602c.

## The engine x thread matrix, measured 2026-09-05

`engine_thread_matrix.clj`, 20k calls per cell, same trivial `add` export, same
process. Run it directly: `./zig-out/bin/cljw .dev/bench/ffi_boundary/engine_thread_matrix.clj`

    cell                     ns/call
    JIT    main thread         16547
    JIT    worker thread        1181
    interp main thread           399
    interp worker thread         413

Three readings, and each names a different fix:

1. **The 14x JIT penalty is entirely the initial thread.** Nothing else differs
   between rows 1 and 2. This is zwasm/D-584 and it is dodgeable without touching
   zwasm: run the invocation on any thread that is not the process's first one.
   `@(future ...)` already does it today, measured at 12.5x on a separate run.
2. **The interpreter is thread-indifferent** (399 vs 413), which confirms it
   caches the stack limit rather than re-querying per call.
3. **Even on a worker thread the JIT is 2.9x the interpreter** on a trivial
   callee. That residual is zwasm/D-585, the per-call module re-parse, now visible
   because zwasm/D-584 has stopped swamping it.

So the engine choice and the thread choice are independent levers, and the right
engine still depends on call shape: the JIT wins 15.5x on compute-in-wasm
(`bench/wasm_jit_vs_interp.sh`) and loses on crossing-heavy work at any thread.

## After ADR-0195, measured 2026-09-06

`cljw` now runs the program on a spawned runtime thread, so "main thread" below
is that thread, not the process's initial one. Loaded host (co-tenant JVM at
~5.6 cores, load average 11-15), minimum of six runs; the interp rows show the
noise floor against 2026-09-05's 399 / 413.

    cell                     ns/call
    JIT    main thread          1150
    JIT    worker thread        1262
    interp main thread           409
    interp worker thread         479

Reading 1 above is closed: rows 1 and 2 are now the same cell. Readings 2 and 3
stand unchanged, and the residual is the next card's target.

## After the exportSig cache, measured 2026-09-06

`Loaded.exportSig` resolves a name once per handle now; on the JIT that was a
module re-parse per call. Same host, same load, minimum of three runs.

    cell                     ns/call
    JIT    main thread           896
    JIT    worker thread         964
    interp main thread           375
    interp worker thread         451

The JIT cells lose ~400-500 ns; the interpreter cells move within noise. The
standing measurement of this axis is now `bench/wasm_percall.sh` (median /
min / max / sd over trials, ns, with a plain Clojure call as the platform
constant); `engine_thread_matrix.clj` stays as the quick 2x2 probe.

Follow-ups: [CLJW-WASM-ENGINE-DEFAULT] landed as ADR-0196 (the default stays
`.auto`; traps name the engine and the shape); [CLJW-WASM-WORKER-THREAD] landed
as ADR-0195; [CLJW-WASM-EXPORTSIG-CACHE] landed. The rest is upstream
(`[ZWASM-PERCALL-TRACK]`).
