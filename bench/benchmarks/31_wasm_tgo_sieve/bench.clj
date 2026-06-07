(require '[cljw.wasm :as wasm])

(def wmod (wasm/load-wasi "bench/wasm/sieve.wasm"))
(def wasm-sieve (wasm/fn wmod "sieve"))

;; Run sieve(65536) 100 times
(loop [i 0 result 0]
  (if (< i 100)
    (recur (inc i) (wasm-sieve 65536))
    (println result)))
