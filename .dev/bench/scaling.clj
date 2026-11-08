;; Complexity-class probe: run the SAME number of operations against
;; collections of growing size. Flat wall-clock across sizes => the operation is
;; O(1)/O(log n) per call; time growing with the size factor => it is O(n).
;;
;; Reported as the ratio t(4n)/t(n). ~1 means constant, ~4 means linear.

(def SIZES [1000 4000 16000])
(def OPS 2000)

(defn- ms [f]
  (let [t0 (System/nanoTime)]
    (f)
    (/ (- (System/nanoTime) t0) 1e6)))

(defn- probe
  "build: size -> collection. op: (fn [coll size]) doing ONE unit of work."
  [label build op]
  (let [times (vec (for [s SIZES]
                     (let [c (build s)]
                       ;; warm
                       (dotimes [_ 50] (op c s))
                       (ms #(dotimes [_ OPS] (op c s))))))
        ratios (vec (map (fn [a b] (if (zero? a) 0.0 (/ b a)))
                         (butlast times) (rest times)))
        worst  (if (seq ratios) (apply max ratios) 0.0)
        verdict (cond (< worst 1.8) "O(1)/O(log n)"
                      (< worst 2.8) "sub-linear?"
                      :else         "O(n)  <-- LINEAR")]
    (println (format "%-26s t=%-28s ratio=%-16s %s"
                     label
                     (vec (map #(format "%.1f" %) times))
                     (vec (map #(format "%.2f" %) ratios))
                     verdict))))

(def V (fn [s] (vec (range s))))
(def M (fn [s] (into {} (map (fn [i] [i i]) (range s)))))
(def S (fn [s] (into #{} (range s))))
(def L (fn [s] (apply list (range s))))

(println "=== cljw collection scaling ===")
(println (format "%d ops per size, sizes %s\n" OPS SIZES))

(println "-- vector --")
(probe "conj"            V (fn [c _] (conj c 1)))
(probe "nth (mid)"       V (fn [c s] (nth c (quot s 2))))
(probe "assoc (mid)"     V (fn [c s] (assoc c (quot s 2) 0)))
(probe "pop"             V (fn [c _] (pop c)))
(probe "count"           V (fn [c _] (count c)))
(probe "peek"            V (fn [c _] (peek c)))
(probe "subvec 1..n"     V (fn [c s] (subvec c 1 s)))
(probe "rest"            V (fn [c _] (rest c)))
(probe "first"           V (fn [c _] (first c)))

(println "\n-- map --")
(probe "assoc (new key)" M (fn [c s] (assoc c (+ s 1) 0)))
(probe "get (hit)"       M (fn [c s] (get c (quot s 2))))
(probe "dissoc"          M (fn [c s] (dissoc c (quot s 2))))
(probe "count"           M (fn [c _] (count c)))
(probe "contains?"       M (fn [c s] (contains? c (quot s 2))))

(println "\n-- set --")
(probe "conj"            S (fn [c s] (conj c (+ s 1))))
(probe "contains?"       S (fn [c s] (contains? c (quot s 2))))
(probe "disj"            S (fn [c s] (disj c (quot s 2))))
(probe "count"           S (fn [c _] (count c)))

(println "\n-- list / seq --")
(probe "list conj"       L (fn [c _] (conj c 1)))
(probe "list first"      L (fn [c _] (first c)))
(probe "list rest"       L (fn [c _] (rest c)))
(probe "list count"      L (fn [c _] (count c)))
