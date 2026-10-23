(defn bench [f n]
  (f)
  (let [runs (for [_ (range 7)]
               (let [t0 (System/nanoTime)] (dotimes [_ n] (f)) (- (System/nanoTime) t0)))]
    (/ (double (apply min runs)) 1e6)))
(def v (vec (range 16000)))
(def xs (mapv double (range 1 1001)))
(prn {:empty-dotimes-20000-ms (let [t0 (System/nanoTime)] (dotimes [_ 20000]) (/ (- (System/nanoTime) t0) 1e6))
      :subvec-20000-ms (bench #(subvec v 100 15000) 1)
      :subvec-x20-ms (bench #(dotimes [_ 20] (subvec v 100 15000)) 1)
      :dot-1k-ms (bench #(reduce + (map * xs xs)) 1)
      :dot-1k-loop-ms (bench #(loop [i 0 acc 0.0] (if (< i 1000) (recur (inc i) (+ acc (* (nth xs i) (nth xs i)))) acc)) 1)})
