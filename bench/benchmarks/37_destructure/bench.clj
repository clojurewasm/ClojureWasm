;; Destructuring: map + vector destructure in a tight loop, 100000x.
;; Pervasive Clojure idiom; cljw-only benchmark.
(def m {:a 1 :b 2 :c 3})
(def v [10 20 30])
(loop [i 0 acc 0]
  (if (< i 100000)
    (let [{:keys [a b c]} m [x y z] v] (recur (inc i) (+ acc a b c x y z)))
    (println acc)))
