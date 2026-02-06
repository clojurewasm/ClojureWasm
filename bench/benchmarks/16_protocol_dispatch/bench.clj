;; Protocol dispatch in tight loop
(defprotocol ICompute
  (compute [this x]))

(extend-type PersistentArrayMap ICompute
             (compute [this x] (* (:factor this) x)))

(defn protocol-bench [n]
  (let [m {:factor 3}]
    (loop [i 0 sum 0]
      (if (= i n)
        sum
        (recur (+ i 1) (+ sum (compute m i)))))))

(println (protocol-bench 10000))
