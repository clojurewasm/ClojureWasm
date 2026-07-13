;; ClojureWasm polyglot FFI demo (ADR-0099 / CFP P1): a Clojure program loads a
;; WebAssembly module compiled from another language and calls it like a
;; namespace. `add.wasm` exports `(add i32 i32) -> i32`.
;;
;;   (wasm/load "path")          → an instance handle
;;   (wasm/call handle "add" …)  → invokes the export, marshalling args/results
;;
;; Run (released binaries — GitHub releases / Homebrew — are wasm-enabled;
;; building from source needs the flag):
;;   zig build -Dwasm
;;   ./zig-out/bin/cljw docs/examples/wasm/add.clj
;; Expected output: 42

(println (wasm/call (wasm/load "docs/examples/wasm/add.wasm") "add" 2 40))
