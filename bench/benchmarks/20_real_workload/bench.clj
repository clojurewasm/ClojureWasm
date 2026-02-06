;; Real workload: build records, filter, map, reduce
(defn make-records [n]
  (loop [i 0 acc []]
    (if (= i n)
      acc
      (recur (+ i 1)
             (conj acc {:id i :value (* i 2) :active (= (mod i 3) 0)})))))

(defn process-records [records]
  (reduce + 0
          (map :value
               (filter :active records))))

(println (process-records (make-records 10000)))
