;; core-library-bound: transducers (transduce, into with an xform).
(def xf (comp (map inc) (filter even?) (map #(* % %))))
(defn work [reps]
  (loop [k 0 s 0]
    (if (< k reps)
      (recur (inc k) (+ s (transduce xf + (range 100000)) (count (into [] xf (range 50000)))))
      s)))
(let [t0 (System/nanoTime) r (work 40)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
