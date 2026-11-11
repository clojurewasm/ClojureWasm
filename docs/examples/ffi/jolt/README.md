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
# jolt_library_init 0 in 495.06 ms
# jolt_lookup add 1085063232 mandel 1085063520 missing 0
# add(2,40) 42 mandel(-0.75,0.1,1000) 33
# grid 300x200 sum 4198758 in 991.74 ms
cljw -M docs/examples/ffi/hive_call.clj docs/examples/ffi/jolt/build/libdemo_named.so ops
# {:ok true, :value [{:doc "Sum of a and b.", :args ["a" "b"], :name "add"}
#             {:doc "Escape count of cr + ci*i, capped at max.", :args ["cr" "ci" "max"], :name "mandel"}
#             {:doc "List the ops this library answers.", :args [], :name "ops"}]}
```

| file | is |
|---|---|
| `src/demo/core.clj` | the jolt library: `add`, `mandel`, and the hive C ABI (`hive_call`, `hive_free`) |
| `build.sh` | builds `build/libdemo.so`, the shim and the C driver |
| `shim.c` | interim: re-exports the looked-up pointers as named symbols |
| `driver.c` | C host: dlopen, init, lookup, call, timed |
| `jolt_lib.clj` | the cljw host |
| `chez.c`, `extract_chez.py` | a `chez` for `jolt build --library`, from the kernel the jolt binary embeds |

## What a jolt library exports

`nm -D --defined-only libdemo.so` lists `jolt_library_init`, `jolt_lookup`,
`jolt_library_release_thread`, `jolt_library_shutdown` and the Chez kernel
(`S*`). The `export!` names are not dynamic symbols: `jolt_lookup("add")`
returns a function pointer, valid after `jolt_library_init`. So cljw can run
the init and the lookups by name today, and it cannot yet call what the lookup
returns. `shim.c` closes the gap for now: it calls the init once, looks the
exports up, and forwards named C functions to them. Once `cljw.ffi` can call
an address (card CLJW-FFI-CALL-ADDRESS, branch `feat/ffi-call-address`) the
host becomes

```clojure
(def lookup (ffi/function lib "jolt_lookup" [:string] :pointer))
(ffi/call lib "jolt_library_init" [:int :pointer] :int 0 nil)
(def add (ffi/function (lookup "add") [:int :int] :int))   ; pending that branch
```

`jolt_lib.clj` already carries this form in `direct` and reports it pending.

## Measured (x86_64 Linux, jolt 0.8.19, cljw 1.15.3)

| | C host | cljw host |
|---|---|---|
| `jolt_library_init` | 236 to 492 ms | 221 to 495 ms warm, 1.5 s cold |
| 60 000 `mandel` calls, 255 iterations max | 200 to 290 ms | 990 to 1060 ms (through the shim) |
| `jolt build --library` | 28 s, 14.9 MB `.so` | |

Init loads a whole Chez heap (the runtime and `clojure.core`) on every
process start. Two collectors, cljw's and Chez's, share the process without
trouble in these runs, including under cljw allocation churn after init.

## The trade

A jolt library is native code. It runs with the ambient authority of the cljw
process (files, network, every byte of memory), carries its own GC and signal
handling, and a fault in it is a fault in cljw. A Wasm guest loaded by cljw is
confined to its own linear memory and to the imports it is given. Use a jolt
library where native speed and the whole Clojure language on the far side are
worth that trust; use a Wasm guest where the code is not yours to trust.

## Building

`jolt build --library` needs Chez's `scheme.h`, `libkernel.a`, the boot files
and a `chez` executable. The prebuilt jolt 0.8.19 embeds the first three as data
but fails with `Chez build file missing: ./../lib/csv10.4.1/ta6le/scheme.h`,
then `chez: not found`. `build.sh` extracts the embedded files into `build/chez/`,
links `chez.c` against them, and sets `JOLT_CHEZ_CSV`. With a from-source Chez
10.4.1 on `PATH` and `JOLT_CHEZ_CSV` set, it uses that instead. Nothing under
`build/` is committed.
