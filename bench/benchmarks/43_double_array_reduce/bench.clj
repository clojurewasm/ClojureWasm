;; Double Array Reduce: (reduce + a) over a 100000-element double-array, 10
;; times. Times reduce's walk over a primitive-array source.
;; Prints the integral result as a long (exact below 2^53).
(def a (double-array (range 100000)))
(loop [i 0 r 0.0]
  (if (< i 10)
    (recur (inc i) (reduce + a))
    (println (long r))))
