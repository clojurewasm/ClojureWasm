;; interpreter-bound: empty fn call plus loop/recur dispatch overhead.
(defn noop [x] x)
(defn work [n]
  (loop [i 0 acc 0]
    (if (< i n) (recur (inc i) (+ acc (noop i))) acc)))
(let [t0 (System/nanoTime) r (work 4000000)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
