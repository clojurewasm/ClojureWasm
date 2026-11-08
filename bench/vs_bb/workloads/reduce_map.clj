;; core-library-bound: (reduce + (map * xs xs)) over 100k doubles (lazy seq machinery).
(def xs (mapv double (range 100000)))
(defn work [reps]
  (loop [k 0 s 0.0] (if (< k reps) (recur (inc k) (+ s (reduce + (map * xs xs)))) s)))
(let [t0 (System/nanoTime) r (work 40)]
  (println "RESULT" (long (/ r 1e9)))
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
