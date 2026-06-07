(def counter (atom 0))

(defn atom-loop [n]
  (loop [i 0]
    (if (= i n)
      (deref counter)
      (do
        (reset! counter (+ (deref counter) 1))
        (recur (+ i 1))))))

(println (atom-loop 10000))
