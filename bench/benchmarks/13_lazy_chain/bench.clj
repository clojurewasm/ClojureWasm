;; Lazy sequence chain: range -> map -> filter -> take -> reduce
(defn lazy-chain [n]
  (reduce + 0
          (take n
                (filter (fn [x] (= (mod x 2) 0))
                        (map (fn [x] (* x 3))
                             (range 1000000))))))

(println (lazy-chain 10000))
