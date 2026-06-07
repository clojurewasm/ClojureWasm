(defn arith-loop [n]
  (loop [i 0 sum 0]
    (if (= i n)
      sum
      (recur (+ i 1) (+ sum i)))))

(println (arith-loop 1000000))
