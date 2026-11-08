;; core-library-bound: byte-array / long-array / double-array from an 8000-element vector.
(def bv (vec (repeat 8000 1)))
(defn work [reps]
  (loop [k 0 s 0]
    (if (< k reps)
      (recur (inc k) (+ s (alength (byte-array bv)) (alength (long-array bv)) (alength (double-array bv))))
      s)))
(let [t0 (System/nanoTime) r (work 900)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
