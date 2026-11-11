;; 10M-iteration loop/recur summing longs.
;; CLJW-PERF-NUMERIC-UNBOX probe. Expected output: 49999995000000
(defn sum-to [n]
  (loop [i 0 acc 0]
    (if (< i n)
      (recur (inc i) (+ acc i))
      acc)))

(println (sum-to 10000000))
