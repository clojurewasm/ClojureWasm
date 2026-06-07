;; Transducer pipeline: map + filter via transduce
(defn transduce-bench [n]
  (transduce
   (comp (map (fn [x] (* x 3)))
         (filter (fn [x] (= (mod x 2) 0))))
   + 0
   (range n)))

(println (transduce-bench 10000))
