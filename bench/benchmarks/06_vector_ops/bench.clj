;; Build vector with conj, then sum with nth
(defn build-vec [n]
  (loop [i 0 v []]
    (if (= i n)
      v
      (recur (+ i 1) (conj v i)))))

(defn sum-vec [v]
  (let [n (count v)]
    (loop [i 0 sum 0]
      (if (= i n)
        sum
        (recur (+ i 1) (+ sum (nth v i)))))))

(println (sum-vec (build-vec 10000)))
