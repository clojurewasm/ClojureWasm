;; collections: into {} / into #{} / frequencies / group-by / sort-by / update.
(defn work [reps]
  (loop [k 0 s 0]
    (if (< k reps)
      (let [v (vec (range 20000))
            m (into {} (map (fn [i] [i (* 2 i)])) v)
            st (into #{} (map #(mod % 1000)) v)
            fr (frequencies (map #(mod % 97) v))
            g (group-by #(mod % 13) v)
            srt (sort-by - v)
            m2 (reduce (fn [acc i] (update acc (mod i 50) (fnil + 0) i)) {} v)]
        (recur (inc k) (+ s (count m) (count st) (count fr) (count g) (first srt) (get m2 7))))
      s)))
(let [t0 (System/nanoTime) r (work 15)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
