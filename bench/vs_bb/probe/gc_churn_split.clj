;; gc_churn split by phase: build the retained heap, then the churn loop and
;; its parts. Runs on cljw and bb alike.
(defn ms [t0] (quot (- (System/nanoTime) t0) 1000000))

(defn timed [label f]
  (let [t0 (System/nanoTime) r (f)]
    (println label (ms t0) r)))

(let [t0 (System/nanoTime)
      retained (vec (map (fn [i] {:id i :v [i (inc i)]}) (range 200000)))]
  (println "build_ms" (ms t0) (count retained))
  (timed "full_loop_ms"
         #(loop [i 0 s 0]
            (if (< i 600000)
              (let [m {:a i :b [i i i] :c {:d (str i)}}]
                (recur (inc i) (+ s (count (:b m)) (count (:c m)))))
              s)))
  (timed "map_vec_ms"
         #(loop [i 0 s 0]
            (if (< i 600000)
              (let [m {:a i :b [i i i]}]
                (recur (inc i) (+ s (count (:b m)))))
              s)))
  (timed "str_ms"
         #(loop [i 0 s 0]
            (if (< i 600000)
              (recur (inc i) (+ s (count (str i))))
              s)))
  (timed "empty_loop_ms"
         #(loop [i 0 s 0]
            (if (< i 600000)
              (recur (inc i) (+ s 1))
              s)))
  (println "retained" (count retained)))
