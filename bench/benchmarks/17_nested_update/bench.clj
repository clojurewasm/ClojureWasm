;; Nested map update: assoc-in / update-in / get-in
(defn nested-bench [n]
  (loop [i 0 m {:a {:b {:c 0}}}]
    (if (= i n)
      (get-in m [:a :b :c])
      (recur (+ i 1) (update-in m [:a :b :c] inc)))))

(println (nested-bench 10000))
