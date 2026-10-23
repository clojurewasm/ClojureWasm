# Polyglot: C, Zig, Rust and Go guests, and three Clojure hosts

One directory, every way another language meets `cljw`. Run it:

```sh
cd docs/examples/polyglot
cljw polyglot.clj        # PASS c-kernel, zig-numeric, rust-core, rust-component, (go-command)
cljw hosts.cljc          # {:host "cljw", :top [["the" 4] ["and" 3] ["cat" 2]], ...}
```

`test/e2e/phase16_wasm_polyglot.sh` runs both files in CI on every push: first
against the committed guests, then against guests rebuilt from the recipe in
each source header, then `hosts.cljc` on every Clojure host on PATH. What this
page claims is what that gate checks.

For Zig beyond scalars (compile-time tables, SIMD, `std.crypto`), and the
same source as a native library through `cljw.ffi`, see
[`../zig-native/`](../zig-native/README.md).

## Three shapes of guest

| guest | source | built with | size | crosses the boundary as | cljw entry point |
|---|---|---|---|---|---|
| C | [`c/kernel.c`](./c/kernel.c) | `zig cc -target wasm32-freestanding` | 2,284 B | scalars; arrays in a guest-owned buffer | `wasm/load`, `wasm/call`, `wasm/mem-write!`, `wasm/mem-read` |
| Zig | [`zig/numeric.zig`](./zig/numeric.zig) | `zig build-exe -target wasm32-freestanding` | 267 B | scalars | `wasm/load`, `wasm/call` |
| Rust, `no_std` | [`rust-core/fib.rs`](./rust-core/fib.rs) | `rustc --target wasm32-unknown-unknown` | 401 B | scalars | `wasm/load`, `wasm/call` |
| Rust, wit-bindgen | [`rust-component/typed_payload.rs`](./rust-component/typed_payload.rs) | `cargo build --target wasm32-wasip2` | 51,636 B | records, lists, strings, `result<T, E>` | `(:require ["./x.wasm" :as x])` |
| Go | [`go/jsonsum.go`](./go/jsonsum.go) | `GOOS=wasip1 GOARCH=wasm go build` | 4,509,209 B, built on demand | argv, env, stdin, stdout, stderr, exit code | `wasm/run` |

**A core module** (C, Zig, Rust without std) is a bag of exports with scalar
signatures. `wasm/call` marshals `i32`/`i64`/`f32`/`f64`; anything larger lives
in the guest's linear memory, and the honest way to share it is for the guest
to hand out an address it owns (`buf_addr` in the C kernel) rather than for the
host to guess a layout. Pick this shape for a hot numeric kernel: one crossing
costs about a microsecond, the body runs on the JIT.

**A WIT component** carries its types. `typed_payload.wit` declares
`record payload { xs: list<u32>, label: string }` and
`process: func(input: payload) -> result<payload, string>`; from Clojure that
is a namespace whose `process` takes a map and returns `[:ok map]` or
`[:err string]`, with `:arglists` from the WIT parameter names. Pick this shape
for a library: the type conversion is generated on both sides and the
component is still sandboxed.

**A WASI command** is a whole program. Go's `wasip1` target is one (a runtime,
a garbage collector and the standard library come along, hence the size), and
its natural boundary is a process boundary: `wasm/run` passes `:args`, `:env`
and `:stdin` and returns `{:out :err :exit}`. Pick this shape when the code is
already a CLI, or when the language's Wasm story is "compile the program", as
Go's is. Nothing is granted that is not passed: without `:dir` the guest has no
filesystem at all.

## What running it taught

Three things the demo surfaced, each now a comment in the source that hit it:

- **The linker's default shadow stack is 1 MB.** A three-function C kernel
  asked for 17 memory pages, so `{:max-memory-pages 16}` refused to
  instantiate it. `-Wl,-z,stack-size=65536` brings it to 2 pages. Budgets are
  about what the module declares, not what it uses.
- **A void export that takes an `f64` has no JIT call shape.** `wasm/call`
  reports it as a trap with the fix in the message: load with
  `{:engine :interp}` or give the export a result. `scale_f64` returns its
  count for that reason.
- **`:args` is the whole argv, program name first**, exactly as a process sees
  it. Go's `os.Args[1:]` is empty when the caller forgets argv[0].

## One program, three hosts

[`hosts.cljc`](./hosts.cljc) computes word frequencies, a ratio and a bigint,
and prints one map. The only host-specific form is the `:host` string, chosen
by reader conditional: `cljw` reads the feature set `{:cljw :clj :default}`,
[clojurust](https://github.com/BuddhiLW/clojurust) (`cljrs`) reads `{:rust}`,
the JVM reads `{:clj :default}`.

```sh
cljw hosts.cljc
cljrs run hosts.cljc
clojure -M hosts.cljc
```

Measured 2026-09-14 (cljw v1.14.7, cljrs 0.1.0, Clojure 1.12): the three lines
differ only in `:host`, including `11/4` and `1000000016000000063`.

## Rebuilding the guests

Each source file carries its own build line. The committed `.wasm` files are
the C, Zig and Rust outputs; the Go binary is gitignored and built on demand:

```sh
(cd go && GOOS=wasip1 GOARCH=wasm go build -o jsonsum.wasm jsonsum.go)
```

The Rust component was built with wit-bindgen 0.36 as described in the zwasm
repository (`test/component/README_typed_payload.md`), which is where the
fixture comes from; it is the same binary zwasm's own typed-invoke tests run.
