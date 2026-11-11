# cljw hosting cljw

cljw builds for `wasm32-wasi` (ADR-0193). That build is a WASI command, so a
native cljw can run it with `wasm/run`: untrusted Clojure evaluated inside the
zwasm sandbox, under fuel, memory, output and wall-clock budgets, with only
the authority the host passes in.

```clojure
(wasm/run "zig-out/bin/cljw.wasm"
          {:args ["cljw" "-"]
           :stdin "(println (reduce + (range 100)))"
           :dir "/tmp/cljw-guest-scratch"})
;=> {:out "4950\n", :err "", :exit 0}
```

## Run it

```sh
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall   # zig-out/bin/cljw.wasm
cljw docs/examples/wasm/clojure-guest/guest.clj
```

The host must be wasm-enabled (`cljw --version` shows `wasm`; the released
binaries are). The `.wasm` is a build output and is not committed. Set
`CLJW_GUEST` to run a guest built elsewhere.

The guest needs one preopened directory. At startup it reads `deps.edn` from
its working directory, and under WASI a relative path needs a preopen to
resolve against; with none, `path_open` gets `EBADF` and the guest exits with
`error: Unexpected` before it reads any input. The same happens under Node's
WASI, so it is the guest, not the engine. An empty scratch directory passed as
`:dir` is enough, and it is then the guest's whole filesystem.

## Measured

2026-11-11. Guest: this tree (v1.15.7), Zig 0.16.0, ReleaseSmall. Host: cljw
v1.15.3 (ReleaseSafe, wasm), x86_64 Linux, with the machine under load
(load average about 34 on 22 cores), so treat the times as upper bounds.

| | |
|---|---|
| `cljw.wasm` size | 3,692,268 B |
| imports | `wasi_snapshot_preview1` only (32 functions) |
| exports | `memory`, `_start` |
| memory floor | starts at 448 pages (28 MiB); 384 pages fails in bootstrap |
| first run (compile, instantiate, eval) | 600 to 700 ms |
| later runs (module cached, instantiate and eval) | 140 to 230 ms |

Every program gave the JVM Clojure answer: `(reduce + (range 100))` 4950, a
recursive `fib` 6765 and 75025, a `map`/`filter`/`reduce` pipeline 1330,
`clojure.string` split, reverse, join and upper-case `"C-B-A"`, a caught
`ex-info` with its message and data. An uncaught exception is `{:exit 1}` with
the message on `:err`.

Both zwasm engines run it. `wasm/run` has no `:engine` option today (it always
uses `:auto`, JIT first), so the per-engine numbers come from the zwasm v2.7.0
CLI, `zwasm run --engine <e> --dir <empty>:. cljw.wasm -`:

| | interpreter | JIT |
|---|---|---|
| `nil` (startup) | 2.8 s | 0.66 s |
| `(fib 25)` | 19.1 s | 1.1 s |
| `(loop [] (recur))`, `--fuel 100000000` | out_of_fuel trap, 2.5 s | out_of_fuel trap, 4.8 s |
| cons forever, `--max-memory 64 MiB` | `OutOfMemory`, 22 s | `OutOfMemory`, 3.1 s |

## Confinement

What each limit does, through `wasm/run` with only `:args`, `:stdin` and an
empty `:dir`:

- **Fuel.** `(loop [] (recur))` with `:fuel 100000000` traps `out_of_fuel` in
  about 4 s and returns `{:out "" :err "" :exit 1}`. With no `:fuel` the
  default budget traps it in about 44 s. `:timeout-ms 2000` with `:fuel 0`
  interrupts it at 2.0 s. The host is never hung and gets data, not an
  exception. The trap text (`zwasm: trap kind=out_of_fuel`) goes to the host
  process's stderr, not into `:err`, so a caller cannot yet tell a fuel trap
  from a timeout from any other exit 1.
- **Memory.** Consing forever under `:max-memory-pages 1024` (64 MiB) ends in
  about 2 s with `{:err "<stdin>: error: OutOfMemory\n" :exit 1}`: the guest's
  allocator sees `memory.grow` refused and fails cleanly. Under the default
  page budget the same happens in about 18 s.
- **Files.** `(slurp "/etc/passwd")` throws inside the guest, catchable there,
  as `slurp '/etc/passwd' failed: AccessDenied`. So does
  `../../../../etc/passwd`. The guest can write in the scratch directory
  (`spit` there succeeds), so pass a fresh directory per run if runs must not
  see each other.
- **Environment.** `(System/getenv "HOME")` is `nil` and `(System/getenv)` is
  `{}`.

## Limits of the wasm32 build

Single-threaded: `future`, `send` to an agent, `pmap` and `Thread.start` each
end the guest with `error: ThreadsUnsupported` and exit 1, which a `try` inside
the guest does not catch. No network (sockets and HTTP are compiled out). No FFI.
It is a stdin-to-stdout evaluator: each `wasm/run` is a fresh instance with no
state carried between runs.
