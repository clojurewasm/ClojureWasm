# bench/vs_bb: cljw vs babashka vs JVM Clojure

Step 0 of decision `20261022012219-31249feb` (make cljw faster than bb, four
measured steps). Kanban `20261022012233-420c9fea`. Each perf step is judged by
this table.

## Why a new set

`bench/benchmarks/*/bench.clj` totals 28-190 ms per run against a startup of
23-27 ms, so startup dominates and the real gap stays hidden (cljw/bb read
1.4-2.5x there, while per-call library code measured 22-37x). Every workload
here runs for at least 300 ms on bb, and the runner reports startup on its own
line.

## Workloads (`workloads/*.clj`)

| file | bound by |
|------|----------|
| fn_call, fib_recursive, dot_loop_nth, protocol_dispatch | interpreter (user code) |
| reduce_map, lazy_chain, transduce, arrays | core library (seq, transducer, array constructors) |
| into_collections, vector_assoc | persistent collections |
| string_ops | strings and regex |
| numeric_doubles | double arithmetic (NaN-boxing vs boxed Double) |
| gc_churn | allocation and GC with a retained heap |
| json_roundtrip | clojure.data.json write and read |

Each file is plain portable Clojure that runs unchanged on cljw, bb and JVM
Clojure. It prints `RESULT <value>`, which the runner checks for equality across
runtimes, and `INPROC_MS <ms>`, the time measured inside the script without
startup or namespace loading.

## Runner

    bash bench/vs_bb/run.sh                  # builds ReleaseSafe -Dwasm into /tmp, 3 runs
    bash bench/vs_bb/run.sh --cljw PATH -n 5 --only reduce_map,arrays
    bash bench/vs_bb/run.sh --perf --probe   # + instructions:u, + per-call probe and RSS probe

Columns: `*_in` is the in-process ms, `*_wl` the process wall ms, `c/bb_in` the
headline ratio cljw/bb on in-process time (below 1.00, cljw is faster),
`c/jvm_in` cljw over warm-ish JVM. The wall column uses hyperfine when it is
installed, otherwise the min of N. Each run appends one YAML row to
`history.yaml`.

On a shared or loaded host, read the ratios. Absolute ms are not comparable
across rows. With `--perf`, the `instructions:u` count is the load-independent
check.

`probe/` holds the original per-call probes (`probe2.clj`: subvec, dot via
reduce/map, dot via loop/nth, byte-array) and the RSS probe (`heap.clj`, with
`heap_bb.clj` for bb, which has no `slurp` of `/proc` files).

## CI

`.github/workflows/bench-vs-bb.yml` runs this on ubuntu for every PR and every
push to main. The job is `continue-on-error`, and `run.sh` exits 0 on a slow or
mismatching workload, so the job is a report and never fails a PR. The table
and the YAML row for that sha are in the run's step summary. It is not part of
the gate, so CI still has one gate configuration (memory
`20260911001202-2ee19e2f`).

## Why bb failed two bench/benchmarks programs

- `16_protocol_dispatch`: `(extend-type PersistentArrayMap ...)` names the class
  unqualified. JVM Clojure and cljw import it implicitly, but SCI does not, so
  bb reports `Unable to resolve symbol: PersistentArrayMap`. Here the workload
  dispatches on a `defrecord` instead.
- `39_json_parse`: `(def doc ...)` clashes with `clojure.repl/doc`, which bb
  refers into `user` (`doc already refers to #'clojure.repl/doc`). JVM `clojure`
  run as a script and cljw do not refer it. Here the var is named `docs`.
