;; interpreter-bound: loop/recur dot product of 1000 doubles via nth.
(def xs (mapv double (range 1 1001)))
(defn dot []
  (loop [i 0 acc 0.0]
    (if (< i 1000) (recur (inc i) (+ acc (* (nth xs i) (nth xs i)))) acc)))
(defn work [reps] (loop [k 0 s 0.0] (if (< k reps) (recur (inc k) (+ s (dot))) s)))
(let [t0 (System/nanoTime) r (work 2500)]
  (println "RESULT" (long r))
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
