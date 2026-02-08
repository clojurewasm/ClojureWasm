;; 02_tinygo_test.clj — E2E test: TinyGo-compiled Wasm module
;; Verifies: wasm/load-wasi, Go→Wasm→Clojure interop

(require '[cljw.wasm :as wasm])

(def go-math (wasm/load-wasi "src/wasm/testdata/09_go_math.wasm"))

(def add      (wasm/fn go-math "add"       {:params [:i32 :i32] :results [:i32]}))
(def multiply (wasm/fn go-math "multiply"  {:params [:i32 :i32] :results [:i32]}))
(def fib      (wasm/fn go-math "fibonacci" {:params [:i32] :results [:i32]}))
(def fact     (wasm/fn go-math "factorial" {:params [:i32] :results [:i32]}))
(def my-gcd   (wasm/fn go-math "gcd"       {:params [:i32 :i32] :results [:i32]}))

;; Basic calls
(assert (= 7 (add 3 4)) "Go add(3,4) should be 7")
(assert (= 42 (multiply 6 7)) "Go multiply(6,7) should be 42")
(assert (= 55 (fib 10)) "Go fib(10) should be 55")
(assert (= 120 (fact 5)) "Go fact(5) should be 120")
(assert (= 6 (my-gcd 12 18)) "Go gcd(12,18) should be 6")

;; Higher-order composition
(assert (= '(1 1 2 3 5 8 13 21 34 55) (map fib (range 1 11)))
        "Go fib(1..10) should match Fibonacci sequence")

;; Sum of squares via Go multiply + Clojure reduce
(assert (= 55 (reduce + (map #(multiply % %) (range 1 6))))
        "Sum of squares 1-5 should be 55")

;; Factorials
(assert (= '(1 2 6 24 120 720 5040) (map fact (range 1 8)))
        "Factorials 1-7 should match")

;; Primes
(def prime? (wasm/fn go-math "is_prime" {:params [:i32] :results [:i32]}))
(assert (= '(2 3 5 7 11 13 17 19 23 29)
           (filter #(= 1 (prime? %)) (range 2 31)))
        "Primes up to 30 should match")

;; GCD of multiple pairs
(assert (= '(6 25 1 12)
           (map (fn [[a b]] (my-gcd a b))
                [[12 18] [100 75] [17 13] [48 36]]))
        "GCD pairs should match")

(println "PASS: 02_tinygo_test")
