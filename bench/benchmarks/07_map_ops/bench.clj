;; Build map with assoc, then sum values with get
(defn build-map [n]
  (loop [i 0 m {}]
    (if (= i n)
      m
      (recur (+ i 1) (assoc m i (* i 1))))))

(defn sum-map [m n]
  (loop [i 0 sum 0]
    (if (= i n)
      sum
      (recur (+ i 1) (+ sum (get m i))))))

(let [n 1000
      m (build-map n)]
  (println (sum-map m n)))
