# cljw calls a Clojure library compiled by jolt

[jolt](https://github.com/jolt-lang/jolt) compiles Clojure to native code on
Chez Scheme. `jolt build --library` turns a namespace into a C-ABI shared
object, and `cljw.ffi` calls it like any other C library.

```clojure
(ns demo.core (:require [jolt.ffi :as ffi]))
(defn add [a b] (+ a b))
(ffi/export! "add" add [:int :int] :int)
```

```sh
sh docs/examples/ffi/jolt/build.sh
cljw -M docs/examples/ffi/jolt/jolt_lib.clj docs/examples/ffi/jolt/build
# jolt_library_init 0 in 169.24 ms
# jolt_lookup add 1097891904 mandel 1097892192 missing 0
# export missing: {:ffi/error :symbol, :address 0}
# add(2,40) 42 mandel(-0.75,0.1,1000) 33
# grid 300x200 sum 4198758 in 406.92 ms
# {:ok true, :value [{:doc "Sum of a and b.", :args ["a" "b"], :name "add"}
#                    {:doc "Escape count of cr + ci*i, capped at max.", :args ["cr" "ci" "max"], :name "mandel"}
#                    {:doc "List the ops this library answers.", :args [], :name "ops"}]}
# {:ok true, :value 42.0}
```

| file | is |
|---|---|
| `src/demo/core.clj` | the jolt library: `add`, `mandel`, and the hive C ABI (`hive_call`, `hive_free`) |
| `build.sh` | builds `build/libdemo.so` and the C driver |
| `driver.c` | C host: dlopen, init, lookup, call, timed |
| `jolt_lib.clj` | the cljw host |
| `chez.c`, `extract_chez.py` | a `chez` for `jolt build --library`, from the kernel the jolt binary embeds |

## What a jolt library exports

`nm -D --defined-only libdemo.so` lists `jolt_library_init`, `jolt_lookup`,
`jolt_library_release_thread`, `jolt_library_shutdown` and the Chez kernel
(`S*`). The `export!` names are not dynamic symbols: `jolt_lookup("add")`
returns a function pointer, valid after `jolt_library_init`, and 0 for a name
the library does not export. cljw calls the two entry points by name and the
returned pointers with `ffi/function-at`:

```clojure
(def lib (ffi/open "build/libdemo.so"))
(ffi/call lib "jolt_library_init" [:int :pointer] :int 0 nil)
(def lookup (ffi/function lib "jolt_lookup" [:string] :pointer))
(def add (ffi/function-at (lookup "add") [:int :int] :int))
(add 2 40)   ;=> 42
```

A name the library lacks gives address 0, which `function-at` refuses with
`{:ffi/error :symbol :address 0}`. `jolt_lib.clj` also speaks the hive C ABI
(`hive_call`, `hive_free`, as `../hive_call.clj` does) over looked-up pointers.
No library owns a looked-up address, so `ffi/close` does not invalidate these
fns: keep `lib` open while they are called.

## Measured

2026-11-11, x86_64 Linux, jolt 0.8.19, cljw 1.15.7 (ReleaseSafe) with
`function-at`. Five runs each, on a host under load (load average about 33),
so the ranges are wide; the C driver ran on the same host in the same minute.

| | C host | cljw host |
|---|---|---|
| `jolt_library_init` | 195 to 223 ms | 169 to 265 ms |
| 60 000 `mandel` calls, 255 iterations max | 175 to 187 ms | 407 to 502 ms |
| `jolt build --library` | 28 s, 14.9 MB `.so` | |

The 60 000-call grid through `function-at` measured the same as through the
interim C shim it replaces (385 to 531 ms over the same five runs), so the
shim is gone and there is one path. Both hosts call the same kernel in the
same library, so the gap to the C host is on the cljw side of the call.

Init loads a whole Chez heap (the runtime and `clojure.core`) on every
process start. Two collectors, cljw's and Chez's, share the process without
trouble in these runs, including under cljw allocation churn after init.

## The trade

A jolt library is native code. It runs with the ambient authority of the cljw
process (files, network, every byte of memory), carries its own GC, installs
its signal handlers at `jolt_library_init`, and a fault in it is a fault in
cljw. A Wasm guest loaded by cljw is confined to its own linear memory and to
the imports it is given. Use a jolt library where native speed and the whole
Clojure language on the far side are worth that trust; use a Wasm guest where
the code is not yours to trust.

## Building

`jolt build --library` needs Chez's `scheme.h`, `libkernel.a`, the boot files
and a `chez` executable. The prebuilt jolt 0.8.19 embeds the first three as data
but fails with `Chez build file missing: ./../lib/csv10.4.1/ta6le/scheme.h`,
then `chez: not found`. `build.sh` extracts the embedded files into `build/chez/`,
links `chez.c` against them, and sets `JOLT_CHEZ_CSV`. With a from-source Chez
10.4.1 on `PATH` and `JOLT_CHEZ_CSV` set, it uses that instead. Nothing under
`build/` is committed.
