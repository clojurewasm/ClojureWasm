;; Whole-collection traversal: does total time scale LINEARLY with n (4x per
;; step) or QUADRATICALLY (16x)? A vector `rest` that materialises would make
;; every seq walk over a vector O(n^2), which matters far more than subvec.

(def SIZES [2000 8000 32000])

(defn- ms [f]
  (let [t0 (System/nanoTime)] (f) (/ (- (System/nanoTime) t0) 1e6)))

(defn- probe [label build run]
  (let [times (vec (for [s SIZES] (let [c (build s)] (ms #(run c)))))
        ratios (vec (map (fn [a b] (if (zero? a) 0.0 (/ b a)))
                         (butlast times) (rest times)))
        worst (if (seq ratios) (apply max ratios) 0.0)
        verdict (cond (< worst 6.0)  "LINEAR O(n)"
                      (< worst 11.0) "superlinear"
                      :else          "QUADRATIC O(n^2)  <-- BAD")]
    (println (format "%-30s t=%-30s ratio=%-14s %s"
                     label
                     (vec (map #(format "%.1f" %) times))
                     (vec (map #(format "%.1f" %) ratios))
                     verdict))))

(def V (fn [s] (vec (range s))))
(def L (fn [s] (apply list (range s))))
(def M (fn [s] (into {} (map (fn [i] [i i]) (range s)))))

(println "=== whole-collection traversal (4x size per step) ===")
(println (format "sizes %s\n" SIZES))

(println "-- over a vector --")
(probe "reduce +"            V #(reduce + 0 %))
(probe "doseq"               V #(doseq [x %] x))
(probe "loop over (rest)"    V #(loop [s (seq %) n 0] (if s (recur (next s) (inc n)) n)))
(probe "count (map inc)"     V #(count (map inc %)))
(probe "count (filter odd?)" V #(count (filter odd? %)))
(probe "last"                V #(last %))
(probe "apply +"             V #(apply + %))
(probe "into [] "            V #(into [] %))
(probe "vec (map inc)"       V #(vec (map inc %)))
(probe "reverse"             V #(reverse %))
(probe "sort"                V #(sort %))
(probe "transduce (map inc)" V #(transduce (map inc) + 0 %))
(probe "into [] xf"          V #(into [] (map inc) %))

(println "\n-- over a list --")
(probe "reduce +"            L #(reduce + 0 %))
(probe "doseq"               L #(doseq [x %] x))

(println "\n-- over a map --")
(probe "reduce-kv +"         M #(reduce-kv (fn [a k _] (+ a k)) 0 %))
(probe "doseq over entries"  M #(doseq [e %] e))
(probe "into {}"             M #(into {} %))
(probe "keys + count"        M #(count (keys %)))

(println "\n-- building --")
(probe "into [] (range n)"   identity #(into [] (range %)))
(probe "reduce conj []"      identity #(reduce conj [] (range %)))
(probe "persistent! loop"    identity
       #(loop [t (transient []) i 0] (if (< i %) (recur (conj! t i) (inc i)) (persistent! t))))
(probe "into #{}"            identity #(into #{} (range %)))
(probe "into {} pairs"       identity #(into {} (map (fn [i] [i i]) (range %))))
(probe "apply str"           identity #(apply str (repeat % "x")))
(probe "str/join"            identity #(clojure.string/join "," (range %)))
