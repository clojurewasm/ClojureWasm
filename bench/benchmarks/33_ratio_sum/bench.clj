;; Numeric tower: exact harmonic sum 1/1..1/50 as a Ratio, 1000x.
;; Clojure-specific (exact rationals); cljw-only benchmark.
(defn harm [n] (reduce + (map #(/ 1 %) (range 1 (inc n)))))
(loop [i 0 r 0]
  (if (< i 1000)
    (recur (inc i) (harm 50))
    (println r)))
