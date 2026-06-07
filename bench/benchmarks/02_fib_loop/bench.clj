(defn fib [n]
  (loop [i 0 a 0 b 1]
    (if (= i n)
      a
      (recur (+ i 1) b (+ a b)))))

(println (fib 25))
