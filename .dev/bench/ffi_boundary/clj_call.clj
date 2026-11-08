;; Same loop shape, same arity, Clojure callee. The subtrahend: whatever this
;; costs is loop + call overhead that the wasm version also pays, so the
;; difference is the crossing itself.
(def m (wasm/load "bench/wasm/ffi/add.wasm" {:fuel 0}))
(defn add2 [a b] (+ a b))
(loop [i 0 acc 0]
  (if (< i 1000000)
    (recur (inc i) (add2 i 1))
    (println acc)))
