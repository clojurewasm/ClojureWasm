;; 04_module_objects.clj — Module keyword lookup and auto-resolve
;; Run: ./zig-out/bin/cljw examples/wasm/04_module_objects.clj

;; ============================================================
;; Part 1: Auto-resolve (no signature needed)
;; ============================================================

(def math (wasm/load "src/wasm/testdata/01_add.wasm"))

;; wasm/fn with 2 args — signature auto-resolved from binary
(def add (wasm/fn math "add"))
(println "Auto-resolve: 3 + 4 =" (add 3 4))      ;; => 7

;; ============================================================
;; Part 2: Export introspection
;; ============================================================

(println "Exports:" (wasm/exports math))
;; => {"add" {:params [:i32 :i32], :results [:i32]}}

;; ============================================================
;; Part 3: Keyword lookup — (:name module)
;; ============================================================

;; (:add math) returns a cached WasmFn
(println "(:add math)(10, 20) =" ((:add math) 10 20))  ;; => 30

;; Module-as-function — (math :add) also works
(println "(math :add)(5, 6) =" ((math :add) 5 6))      ;; => 11

;; String key also works
(println "(math \"add\")(1, 2) =" ((math "add") 1 2))  ;; => 3

;; ============================================================
;; Part 4: Fibonacci with keyword lookup
;; ============================================================

(def fib-mod (wasm/load "src/wasm/testdata/02_fibonacci.wasm"))
(println "fib(10) =" ((:fib fib-mod) 10))               ;; => 55
(println "fib(1..10):" (map (:fib fib-mod) (range 1 11)))
;; => (1 1 2 3 5 8 13 21 34 55)

;; ============================================================
;; Part 5: Memory module with multiple exports
;; ============================================================

(def mem-mod (wasm/load "src/wasm/testdata/03_memory.wasm"))
(println "Memory exports:" (wasm/exports mem-mod))

;; Use keyword lookup for store/load
((:store mem-mod) 0 42)
(println "mem[0] =" ((:load mem-mod) 0))  ;; => 42

(println "04_module_objects done.")
