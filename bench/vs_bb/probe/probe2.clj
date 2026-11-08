(defn per-call-us [f n]
  (dotimes [_ 2000] (f))
  (let [runs (for [_ (range 7)]
               (let [t0 (System/nanoTime)] (dotimes [_ n] (f)) (- (System/nanoTime) t0)))]
    (/ (double (apply min runs)) n 1e3)))
(def v (vec (range 16000)))
(def xs (mapv double (range 1 1001)))
(prn {:version (clojure-version)
      :subvec-us (per-call-us #(subvec v 100 15000) 2000)
      :dot-1k-reduce-map-us (per-call-us #(reduce + (map * xs xs)) 200)
      :dot-1k-loop-nth-us (per-call-us #(loop [i 0 acc 0.0] (if (< i 1000) (recur (inc i) (+ acc (* (nth xs i) (nth xs i)))) acc)) 200)
      :byte-array-vec-8000-us (let [bv (vec (repeat 8000 1))] (per-call-us #(byte-array bv) 50))})
