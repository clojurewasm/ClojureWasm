;; interpreter-bound: protocol dispatch on a record (portable: names no host class).
(defprotocol ICompute (compute [this x]))
(defrecord Scaler [factor] ICompute (compute [_ x] (* factor x)))
(defn work [n]
  (let [s (->Scaler 3)]
    (loop [i 0 sum 0] (if (< i n) (recur (inc i) (+ sum (compute s i))) sum))))
(let [t0 (System/nanoTime) r (work 2000000)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
