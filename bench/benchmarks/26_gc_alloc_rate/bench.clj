;; GC alloc rate: pure allocation throughput with minimal computation
;; Creates 200K short-lived vectors — measures raw allocation + GC speed
(defn alloc-rate [n]
  (loop [i 0 sum 0]
    (if (= i n)
      sum
      (let [v [i (+ i 1) (+ i 2) (+ i 3)]]
        (recur (+ i 1) (+ sum (nth v 2)))))))

(println (alloc-rate 200000))
