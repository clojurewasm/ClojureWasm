(require '[cljw.wasm :as wasm])

(def wmod (wasm/load-wasi "bench/wasm/arith.wasm"))
(def wasm-arith (wasm/fn wmod "arith_loop"))

;; Call wasm arith_loop(1000000) 10 times
(loop [i 0 result 0]
  (if (< i 10)
    (recur (inc i) (wasm-arith 1000000))
    (println result)))
