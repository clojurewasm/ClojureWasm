# What works — a runnable demo walkthrough

A code-first tour of what ClojureWasm (`cljw`) does today. Everything here is
runnable on a current build (`zig build`, then `alias cljw=./zig-out/bin/cljw`).
The companion [`ladder.md`](./ladder.md) tracks real-world library loading; this
file is the "here is what works, run it yourself" ledger.

## 1. The language is really there

```clojure
cljw -e "(+ 1/3 1/6)"                       ;=> 1/2          ; real Ratio
cljw -e "(* 1234567890987654321 1000)"      ;=> 1234567890987654321000N   ; Long→BigInt
cljw -e "(take 5 (map #(* % %) (range)))"   ;=> (0 1 4 9 16)              ; lazy seq
cljw -e "(into [] (comp (filter odd?) (map inc)) (range 6))"  ;=> [2 4 6]  ; transducers
cljw -e "(let [{:keys [a b] :or {b 9}} {:a 1}] [a b])"        ;=> [1 9]    ; destructuring
```

Software transactional memory, protocols/records/multimethods, `deftype`/`reify`,
namespaces, and a CIDER-compatible nREPL (`cljw nrepl`) all work — see the README.

Correctness is mechanical: every e2e runs on **both** a tree-walking interpreter
and a bytecode VM and the build fails if they disagree, plus a differential corpus
against the real `clj`.

## 2. Polyglot — call another language's Wasm from Clojure

Build with the FFI: `zig build -Dwasm`. `add.wasm` exports `(add i32 i32) -> i32`:

```clojure
cljw -e '(wasm/call (wasm/load "examples/wasm/add.wasm") "add" 2 40)'   ;=> 42
```

A Wasm-side trap surfaces as a clean Clojure exception (catchable with `try`).
Today the calls are pure computation; host capabilities for I/O-bound modules are
being extended. (The line: cljw *calls* Wasm; compiling cljw itself *to* Wasm is
still ahead.)

## 3. A real app — the Bookshelf (the polyglot story inside a real web app)

[`clojurewasm/cw-serverless-demo`](https://github.com/clojurewasm/cw-serverless-demo)
(<https://cw-serverless-demo.fly.dev>) — a multi-user bookshelf served end-to-end
by cljw's own HTTP server, no JVM. Sign in with Google, build your shelf, browse
others — sessions, CRUD, persistence, server-rendered SPA.

The polyglot story runs *inside* the app, both over the Wasm FFI:

- **SQLite** is `sqlite3.wasm` (the C amalgamation + a first-party wrapper, compiled
  with `zig cc --target=wasm32-wasi`) driven by `(wasm/run …)` — real SQL, file
  persistence, no file-VFS.
- **Book-cover colours** come from a hand-written Rust module via `(wasm/call …)`.

It deploys self-contained: the `Dockerfile` builds `cljw` from source (`-Dwasm`
ReleaseSafe; zwasm via a pinned tag), and the SQLite store persists on a Fly
volume. Config is environment-driven (`GOOGLE_CLIENT_ID` via `fly secrets`).

## 4. A Playground — eval Clojure on cljw in the browser

[`clojurewasm/cw-playground`](https://github.com/clojurewasm/cw-playground)
(<https://cw-playground.fly.dev>) — type Clojure, run it on cljw (not JVM Clojure),
see the printed output and result. Submissions are evaluated **in-process** on the
server's cljw under a per-submission budget (`cljw.eval/with-budget` — steps /
deadline / heap; a runaway is recovered as a value so the server survives), and can
call sandboxed Rust and Go WebAssembly modules over the FFI. Example snippets cover
the numeric tower, ratios, lazy seqs, STM, and the Wasm modules.

## The honest edges

- Verified on macOS arm64 + Ubuntu x86_64 only.
- Throughput/GC have headroom; the strengths are startup (~4–5 ms), size (<4 MB),
  and a small footprint.
- The deployed demos run a Debian-slim (glibc) image with the full `-Dwasm` build,
  so the polyglot Wasm FFI is live in production. (A static-musl build still omits
  `-Dwasm` — zwasm's GC uses a glibc-only `pthread_getattr_np` — but the Fly demos
  do not use musl.)
- Deep Java interop (gen-class / deep proxy / deep reflection) is out of scope by
  design — this targets the "call Wasm from Clojure" corner, not a JVM replacement.
