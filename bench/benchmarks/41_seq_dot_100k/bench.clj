;; Seq Dot Product 100k: the 40_seq_dot_1k workload over a 100000-element
;; vector, 10 times. Same per-element work; the live set is 100x larger, so
;; the gap to 40_seq_dot_1k per element is the GC / cache cost of the heap.
;; Prints the integral result as a long (exact: sum of i^2 below 2^53).
(def xs (vec (map double (range 100000))))
(loop [i 0 r 0.0]
  (if (< i 10)
    (recur (inc i) (reduce + (map * xs xs)))
    (println (long r))))
