;; 01_basic_test.clj — E2E test: basic Wasm interop
;; Verifies: wasm/load, wasm/fn, function calls, memory operations

(require '[cljw.wasm :as wasm])

;; Part 1: Loading and calling Wasm functions
(def math (wasm/load "src/app/wasm/testdata/01_add.wasm"))
(def add (wasm/fn math "add" {:params [:i32 :i32] :results [:i32]}))

(assert (= 7 (add 3 4)) "add(3, 4) should be 7")
(assert (= 300 (add 100 200)) "add(100, 200) should be 300")
(assert (= 0 (add 0 0)) "add(0, 0) should be 0")
(assert (= -1 (add 0 -1)) "add(0, -1) should be -1")

;; Part 2: Fibonacci
(def fib-mod (wasm/load "src/app/wasm/testdata/02_fibonacci.wasm"))
(def fib (wasm/fn fib-mod "fib" {:params [:i32] :results [:i32]}))

(assert (= 55 (fib 10)) "fib(10) should be 55")
(assert (= 6765 (fib 20)) "fib(20) should be 6765")
(assert (= '(1 1 2 3 5 8 13 21 34 55) (map fib (range 1 11)))
        "fib(1..10) should match")

;; Part 3: Memory operations
(def mem-mod (wasm/load "src/app/wasm/testdata/03_memory.wasm"))
(def wasm-store (wasm/fn mem-mod "store" {:params [:i32 :i32] :results []}))
(def wasm-load (wasm/fn mem-mod "load" {:params [:i32] :results [:i32]}))

(wasm-store 0 42)
(assert (= 42 (wasm-load 0)) "mem[0] should be 42")

;; UTF-8 string round-trip
(wasm/memory-write mem-mod 256 "Hello, Wasm!")
(assert (= "Hello, Wasm!" (wasm/memory-read mem-mod 256 12))
        "String round-trip should match")

;; Japanese text round-trip
(wasm/memory-write mem-mod 512 "こんにちは")
(assert (= "こんにちは" (wasm/memory-read mem-mod 512 15))
        "Japanese text round-trip should match")

;; Sum range via Wasm
(def sum-range (wasm/fn mem-mod "sum_range" {:params [:i32 :i32] :results [:i32]}))
(wasm-store 100 10)
(wasm-store 104 20)
(wasm-store 108 30)
(assert (= 60 (sum-range 100 3)) "sum(10,20,30) should be 60")

;; Part 4: Recursive function calls with memory (nqueens)
;; Regression test for label stack leak on function return (F138).
(def nq-mod (wasm/load "src/app/wasm/testdata/25_nqueens.wasm"))
(def nqueens (wasm/fn nq-mod "nqueens" {:params [:i32] :results [:i32]}))

(assert (= 92 (nqueens 8)) "nqueens(8) should be 92")
(assert (= 92 (nqueens 8)) "nqueens(8) repeated should be 92")

(println "PASS: 01_basic_test")
