;; Sort: sort a 5000-element descending vector ascending, 5x;
;; prints the sum of the 100 smallest (5050), stable across runs/languages.
(def v (vec (range 5000 0 -1)))
(loop [i 0 r 0]
  (if (< i 5)
    (recur (inc i) (reduce + (take 100 (sort v))))
    (println r)))
