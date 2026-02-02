;; Build a list of 10000 numbers using loop/recur (no range)
(defn make-list [n]
  (loop [i 0 acc (list)]
    (if (= i n)
      acc
      (recur (+ i 1) (cons i acc)))))

(let [xs (make-list 10000)
      mapped (map (fn [x] (* x x)) xs)
      filtered (filter (fn [x] (= (mod x 2) 0)) mapped)
      result (reduce + 0 filtered)]
  (println result))
