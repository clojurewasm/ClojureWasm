;; Multimethod dispatch in tight loop
(defmulti process (fn [x] (:type x)))
(defmethod process :add [x] (+ (:a x) (:b x)))
(defmethod process :mul [x] (* (:a x) (:b x)))
(defmethod process :sub [x] (- (:a x) (:b x)))

(defn multi-bench [n]
  (let [data {:type :add :a 3 :b 4}]
    (loop [i 0 sum 0]
      (if (= i n)
        sum
        (recur (+ i 1) (+ sum (process data)))))))

(println (multi-bench 10000))
