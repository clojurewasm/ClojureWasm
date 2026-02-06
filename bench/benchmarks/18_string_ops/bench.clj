;; String operations: str conversion + count in tight loop
(defn string-bench [n]
  (loop [i 0 sum 0]
    (if (= i n)
      sum
      (let [s (str i)]
        (recur (+ i 1) (+ sum (count s)))))))

(println (string-bench 100000))
