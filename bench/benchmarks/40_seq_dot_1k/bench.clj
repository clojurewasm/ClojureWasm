;; Seq Dot Product 1k: the idiomatic dot product, (reduce + (map * xs xs)),
;; over a 1000-element vector of doubles, 1000 times. The 2-coll `map` arm is
;; unchunked, so this times one lazy cell + one fn call per element.
;; Prints the integral result as a long (exact: sum of i^2 below 2^53).
(def xs (vec (map double (range 1000))))
(loop [i 0 r 0.0]
  (if (< i 1000)
    (recur (inc i) (reduce + (map * xs xs)))
    (println (long r))))
