;; GC large heap: GC cycle time with many live objects
;; Builds a vector of 100K maps (all retained), then sums a field
;; Forces GC to trace a large live set during allocation
(defn large-heap [n]
  (let [data (into [] (map (fn [i] {:id i :val (+ i 1)}) (range n)))]
    (reduce (fn [sum m] (+ sum (get m :val))) 0 data)))

(println (large-heap 100000))
