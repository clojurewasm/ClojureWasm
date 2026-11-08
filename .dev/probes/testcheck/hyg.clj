(ns hyg (:refer-clojure :exclude [seq]))
(defn seq [x] :shadowed)
(println (vec (for [i (range 3)] (* i i))))
