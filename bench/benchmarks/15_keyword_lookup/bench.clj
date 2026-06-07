;; Keyword map lookup in tight loop
(defn keyword-bench [n]
  (let [m {:name "Alice" :age 30 :city "NYC" :score 95 :level 5}]
    (loop [i 0 sum 0]
      (if (= i n)
        sum
        (recur (+ i 1) (+ sum (:score m)))))))

(println (keyword-bench 100000))
