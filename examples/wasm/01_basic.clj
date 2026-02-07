;; 01_basic.clj — Wasm basic interop examples
;; Run: ./zig-out/bin/cljw examples/wasm/01_basic.clj

;; ============================================================
;; Part 1: Loading and calling Wasm functions
;; ============================================================

;; Load a pure Wasm module (compiled from WAT)
(def math (wasm/load "src/wasm/testdata/01_add.wasm"))
;; => #<WasmModule>

;; Create a callable function with type signature
(def add (wasm/fn math "add" {:params [:i32 :i32] :results [:i32]}))
;; => #<WasmFn add>

;; Call it like any Clojure function
(println "3 + 4 =" (add 3 4))          ;; => 7
(println "100 + 200 =" (add 100 200))  ;; => 300

;; ============================================================
;; Part 2: Fibonacci — recursive Wasm function
;; ============================================================

(def fib-mod (wasm/load "src/wasm/testdata/02_fibonacci.wasm"))
(def fib (wasm/fn fib-mod "fib" {:params [:i32] :results [:i32]}))

(println "fib(10) =" (fib 10))   ;; => 55
(println "fib(20) =" (fib 20))   ;; => 6765

;; Wasm functions work with Clojure higher-order functions
(println "fib(1..10):" (map fib (range 1 11)))
;; => (1 1 2 3 5 8 13 21 34 55)

;; ============================================================
;; Part 3: Memory operations
;; ============================================================

(def mem-mod (wasm/load "src/wasm/testdata/03_memory.wasm"))
(def wasm-store (wasm/fn mem-mod "store" {:params [:i32 :i32] :results []}))
(def wasm-load (wasm/fn mem-mod "load" {:params [:i32] :results [:i32]}))

;; Store/load i32 values via Wasm functions
(wasm-store 0 42)
(println "mem[0] =" (wasm-load 0))  ;; => 42

;; Direct byte-level memory access (UTF-8 strings)
(wasm/memory-write mem-mod 256 "Hello, Wasm!")
(println (wasm/memory-read mem-mod 256 12))  ;; => "Hello, Wasm!"

;; Japanese text (UTF-8 multibyte)
(wasm/memory-write mem-mod 512 "こんにちは")
(println (wasm/memory-read mem-mod 512 15))  ;; => "こんにちは"

;; Sum computed by Wasm over memory region
(def sum-range (wasm/fn mem-mod "sum_range" {:params [:i32 :i32] :results [:i32]}))
(wasm-store 100 10)
(wasm-store 104 20)
(wasm-store 108 30)
(println "sum(10,20,30) =" (sum-range 100 3))  ;; => 60

(println "01_basic done.")
