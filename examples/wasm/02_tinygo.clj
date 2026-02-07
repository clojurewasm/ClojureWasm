;; 02_tinygo.clj — Go -> Wasm -> ClojureWasm (multi-language interop)
;; Run: ./zig-out/bin/cljw examples/wasm/02_tinygo.clj
;;
;; The Go source is at test/wasm/src/go_math.go
;; Compile with: tinygo build -o src/wasm/testdata/09_go_math.wasm -target=wasi -no-debug test/wasm/src/go_math.go

;; ============================================================
;; Part 1: Load TinyGo-compiled Wasm module
;; ============================================================

;; TinyGo compiles with -target=wasi, so use load-wasi
(def go-math (wasm/load-wasi "src/wasm/testdata/09_go_math.wasm"))

;; Bind exported Go functions as first-class Clojure functions
(def add      (wasm/fn go-math "add"       {:params [:i32 :i32] :results [:i32]}))
(def multiply (wasm/fn go-math "multiply"  {:params [:i32 :i32] :results [:i32]}))
(def fib      (wasm/fn go-math "fibonacci" {:params [:i32] :results [:i32]}))
(def fact     (wasm/fn go-math "factorial" {:params [:i32] :results [:i32]}))
(def my-gcd   (wasm/fn go-math "gcd"       {:params [:i32 :i32] :results [:i32]}))

;; ============================================================
;; Part 2: Call Go functions from Clojure
;; ============================================================

(println "add(3, 4) =" (add 3 4))          ;; => 7
(println "multiply(6, 7) =" (multiply 6 7)) ;; => 42
(println "fib(10) =" (fib 10))              ;; => 55
(println "fact(5) =" (fact 5))              ;; => 120
(println "gcd(12, 18) =" (my-gcd 12 18))    ;; => 6

;; ============================================================
;; Part 3: Compose with Clojure higher-order functions
;; ============================================================

;; Fibonacci sequence via map
(println "fib(1..10):" (map fib (range 1 11)))
;; => (1 1 2 3 5 8 13 21 34 55)

;; Sum of squares via Go multiply + Clojure reduce
(println "sum of squares 1-5:"
         (reduce + (map #(multiply % %) (range 1 6))))
;; => 55  (1 + 4 + 9 + 16 + 25)

;; Factorials via map
(println "factorials:" (map fact (range 1 8)))
;; => (1 2 6 24 120 720 5040)

;; Filter primes using Go is_prime
(def prime? (wasm/fn go-math "is_prime" {:params [:i32] :results [:i32]}))
(println "primes up to 30:"
         (filter #(= 1 (prime? %)) (range 2 31)))
;; => (2 3 5 7 11 13 17 19 23 29)

;; GCD of multiple pairs
(println "GCDs:" (map (fn [[a b]] (my-gcd a b))
                      [[12 18] [100 75] [17 13] [48 36]]))
;; => (6 25 1 12)

(println "02_tinygo done.")
