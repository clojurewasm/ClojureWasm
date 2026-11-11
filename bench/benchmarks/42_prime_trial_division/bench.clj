;; Prime Trial Division: the 1000th prime by trial division up to sqrt(n).
;; Nested loop/recur over fixnums plus one fn call per candidate.
(defn prime? [n]
  (loop [d 2]
    (cond (> (* d d) n) true
          (zero? (rem n d)) false
          :else (recur (inc d)))))
(defn nth-prime [k]
  (loop [n 2 c 0]
    (if (prime? n)
      (if (= (inc c) k) n (recur (inc n) (inc c)))
      (recur (inc n) c))))
(println (nth-prime 1000))
