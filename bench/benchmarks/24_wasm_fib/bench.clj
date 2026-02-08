(require '[cljw.wasm :as wasm])

(def wmod (wasm/load "src/wasm/testdata/02_fibonacci.wasm"))
(def wasm-fib (wasm/fn wmod "fib"))

;; Call wasm fib(20) 10000 times
(loop [i 0 result 0]
  (if (< i 10000)
    (recur (inc i) (wasm-fib 20))
    (println result)))
