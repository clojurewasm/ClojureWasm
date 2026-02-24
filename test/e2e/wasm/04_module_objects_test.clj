;; 04_module_objects_test.clj — E2E test: module auto-resolve and keyword lookup
;; Verifies: auto-resolve signatures, wasm/exports, keyword lookup

(require '[cljw.wasm :as wasm])

;; Part 1: Auto-resolve (no signature needed)
(def math (wasm/load "src/app/wasm/testdata/01_add.wasm"))
(def add (wasm/fn math "add"))
(assert (= 7 (add 3 4)) "Auto-resolved add(3,4) should be 7")

;; Part 2: Export introspection
(let [exports (wasm/exports math)]
  (assert (map? exports) "exports should be a map")
  (assert (contains? exports "add") "exports should contain 'add'"))

;; Part 3: Keyword lookup — (:name module)
(assert (= 30 ((:add math) 10 20)) "(:add math)(10,20) should be 30")

;; Module-as-function — (math :add)
(assert (= 11 ((math :add) 5 6)) "(math :add)(5,6) should be 11")

;; String key
(assert (= 3 ((math "add") 1 2)) "(math \"add\")(1,2) should be 3")

;; Part 4: Fibonacci with keyword lookup
(def fib-mod (wasm/load "src/app/wasm/testdata/02_fibonacci.wasm"))
(assert (= 55 ((:fib fib-mod) 10)) "Keyword fib(10) should be 55")
(assert (= '(1 1 2 3 5 8 13 21 34 55)
           (map (:fib fib-mod) (range 1 11)))
        "Keyword fib(1..10) should match")

;; Part 5: Memory module with multiple exports
(def mem-mod (wasm/load "src/app/wasm/testdata/03_memory.wasm"))
(let [exports (wasm/exports mem-mod)]
  (assert (map? exports) "Memory exports should be a map")
  (assert (contains? exports "store") "Should contain 'store'")
  (assert (contains? exports "load") "Should contain 'load'"))

;; Keyword lookup for store/load
((:store mem-mod) 0 42)
(assert (= 42 ((:load mem-mod) 0)) "Keyword mem[0] should be 42")

(println "PASS: 04_module_objects_test")
