# WebAssembly as an FFI — polyglot demo

ClojureWasm can embed a WebAssembly engine ([zwasm](https://github.com/zwasm/zwasm)
v2) and call modules compiled from **other languages** as if they were Clojure
namespaces. This is the "WebAssembly as an FFI" idea: a Clojure REPL loads a
sandboxed `.wasm` and invokes its exports.

```clojure
(def m (wasm/load "docs/examples/wasm/add.wasm"))
(wasm/call m "add" 2 40)   ;=> 42
```

`wasm/load` reads + instantiates a module; `wasm/call` invokes an export by
name, marshalling arguments and results from the export's signature
(`i32`/`i64`/`f32`/`f64` today).

A module handle also answers Clojure's host-interop method syntax (ADR-0203):
the method name is the export name, verbatim, and the call is `wasm/call`'s
own path, so results, fuel limits and traps behave the same.

```clojure
(.add m 40 2)       ;=> 42
(. m add 40 2)      ;=> 42
(. m (add 40 2))    ;=> 42

;; A C kernel (../polyglot/c/kernel.c): C names work as written.
(def k (wasm/load "docs/examples/polyglot/c/kernel.wasm"))
(def buf (.buf_addr k))
(wasm/mem-write! k :f64 buf [1.0 2.0 3.0 4.0])
(.sum_f64 k buf 4)  ;=> 10.0
```

`wasm/mem-write!` takes a vector, or a primitive array (`double-array`,
`long-array`, ...). An array whose element matches the dtype (`:f64` and a
double-array, `:i64` and a long-array, `:i32` and an int-array) is copied in
with one memcpy; a vector is encoded one element at a time.
`wasm/mem-read-array` is the bulk read: it answers a primitive array of the
dtype's width (`:u16` widens to an int-array, `:u32` to a long-array).

```clojure
(wasm/mem-write! k :f64 buf (double-array [1 2 3 4]))
(vec (wasm/mem-read-array k :f64 buf 4))  ;=> [1.0 2.0 3.0 4.0]
```

## Run it

The **released binaries** (GitHub releases, `brew install
buddhilw/tap/cljw`) are wasm-enabled — `cljw --version` shows `wasm` —
so they run this demo directly. Building from source, the FFI is behind a
build flag (`-Dwasm`); a bare `zig build` does not embed zwasm:

```sh
zig build -Dwasm
./zig-out/bin/cljw docs/examples/wasm/add.clj
# 42
```

(A **component-model** binary — as opposed to a plain module like this
demo's — can additionally be required like a namespace via
`cljw.wasm/require-component`, interning each export as a var.)

## The module

`add.wasm` is a 41-byte module exporting `(add i32 i32) -> i32`. It is committed
prebuilt so the demo needs no wasm toolchain. The human-readable source is
[`add.wat`](./add.wat); rebuild with any wabt/wasm toolchain:

```sh
wat2wasm add.wat -o add.wasm
```

Any language that compiles to WebAssembly works the same way — a Rust crate, a
Zig module, a C function — once built to a `.wasm`, its exports are callable
from Clojure through `wasm/load` + `wasm/call`. The worked, gated versions of
that sentence (C, Zig, Rust core module, Rust WIT component, Go WASI command,
each with its build line) are in [`../polyglot/`](../polyglot/README.md).

## Sandboxing

The module runs inside the wasm engine's sandbox: it has no ambient access to
the filesystem or network, and its linear memory is isolated from the
ClojureWasm heap. This demo module is pure compute (`add`); host capabilities
(for modules that need I/O) are an explicit, opt-in import.

A faulty or adversarial module's **trap** is contained and surfaces as an
ordinary Clojure exception — the host never crashes. [`trap.wat`](./trap.wat)
divides by zero:

```clojure
(try
  (wasm/call (wasm/load "docs/examples/wasm/trap.wasm") "boom")
  (catch Throwable e (println "caught trap:" (.getMessage e))))
;; caught trap: wasm/call: 'boom' () -> (i32) trapped on the auto (JIT-first) engine (divide-by-zero, …)
```

Run it: `zig build -Dwasm && ./zig-out/bin/cljw docs/examples/wasm/trap.clj`.

## Engines

`wasm/load` takes `{:engine :auto}` (the default: zwasm's JIT, with a fallback
to its interpreter when the JIT cannot build the module), `:jit` or `:interp`;
`(wasm/engine handle)` returns the selection a handle was loaded with. The two
engines trade differently: the JIT runs a compute-bound body about 15x faster,
while one `wasm/call` crossing costs about 0.4 us on the interpreter and about
1.15 us on the JIT (x86_64 Linux), so a call whose body is shorter than roughly
a microsecond is cheaper on `:interp`. Each engine also has call shapes it
cannot dispatch today; when such a call traps, the message names the export,
its signature, the engine and the option to pass instead.
