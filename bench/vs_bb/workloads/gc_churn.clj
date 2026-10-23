;; GC heavy: many short-lived maps and vectors over a retained large heap.
(defn work [n]
  (let [retained (vec (map (fn [i] {:id i :v [i (inc i)]}) (range 200000)))]
    (loop [i 0 s 0]
      (if (< i n)
        (let [m {:a i :b [i i i] :c {:d (str i)}}]
          (recur (inc i) (+ s (count (:b m)) (count (:c m)))))
        (+ s (count retained) (:id (nth retained 1234)))))))
(let [t0 (System/nanoTime) r (work 600000)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
