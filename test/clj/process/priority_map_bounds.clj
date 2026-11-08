;; D-530: real Sorted/Seqable overload consumer, with its library on the classpath.
(ns process.priority-map-bounds
  (:require [clojure.data.priority-map :as pm]))

(let [p (pm/priority-map :a 3 :b 1 :c 2 :d 4)]
  (assert (= ['([:b 1] [:c 2]) '([:d 4] [:a 3] [:c 2])]
             [(subseq p < 3) (rsubseq p > 1)])
          "priority-map sorted bounds"))
(println "PASS priority_map_bounds")
