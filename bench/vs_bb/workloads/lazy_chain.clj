;; core-library-bound: a lazy map/filter/take chain over an infinite range.
(defn work [reps]
  (loop [k 0 s 0]
    (if (< k reps)
      (recur (inc k) (+ s (reduce + (take 50000 (filter odd? (map #(* 3 %) (range)))))))
      s)))
(let [t0 (System/nanoTime) r (work 15)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
