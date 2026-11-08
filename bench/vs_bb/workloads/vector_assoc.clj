;; collections: persistent vector conj/assoc/subvec and keyword-map assoc/dissoc churn.
(defn work [n]
  (let [v (loop [i 0 v []] (if (< i n) (recur (inc i) (conj v i)) v))
        v2 (loop [i 0 v v] (if (< i n) (recur (inc i) (assoc v i (- i))) v))
        m (loop [i 0 m {}] (if (< i n) (recur (inc i) (assoc m (keyword (str "k" (mod i 5000))) i)) m))
        m2 (reduce dissoc m (take 1000 (keys m)))
        sv (loop [i 0 s 0] (if (< i 2000) (recur (inc i) (+ s (count (subvec v2 i (+ i 1000))))) s))]
    (+ (count v) (reduce + v2) (count m2) sv)))
(let [t0 (System/nanoTime) r (work 300000)]
  (println "RESULT" r)
  (println "INPROC_MS" (quot (- (System/nanoTime) t0) 1000000)))
