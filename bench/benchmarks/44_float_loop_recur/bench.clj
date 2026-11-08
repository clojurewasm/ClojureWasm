;; Float Loop Recur: a 1M-iteration loop/recur whose accumulator is a double
;; and whose counter is a long, so every step does mixed double/long `*` and
;; `+`. Prints the result as a long (every partial sum is exact below 2^53).
(println (long (loop [i 0 acc 0.0]
                 (if (< i 1000000)
                   (recur (inc i) (+ acc (* 1.5 i)))
                   acc))))
