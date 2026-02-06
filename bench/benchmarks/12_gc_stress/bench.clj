;; GC stress: allocation-heavy loop creating 100K short-lived maps
(defn gc-stress [n]
  (loop [i 0 sum 0]
    (if (= i n)
      sum
      (let [m {:a i :b (+ i 1) :c (+ i 2)}]
        (recur (+ i 1) (+ sum (get m :b)))))))

(println (gc-stress 100000))
