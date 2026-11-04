;; String-seq workloads ([CLJW-STRING-SEQ], A13 `.string_seq`).
;;
;; Two questions, same method as traversal.clj / scaling.clj:
;;  - FIXED-OPS probes (2000 ops after warmup) against strings of growing size:
;;    flat time across sizes = O(1) per op; growing with size = O(n) per op.
;;  - WHOLE-WALK probes: total time 4x per 4x size = linear, 16x = quadratic.
;;
;; Run:  cljw .dev/bench/string_seq.clj      clj -M .dev/bench/string_seq.clj

(def SIZES [2000 8000 32000])
(def OPS 2000)

(defn- ms [f]
  (let [t0 (System/nanoTime)] (f) (/ (- (System/nanoTime) t0) 1e6)))

(defn- best-of [k f] (apply min (repeatedly k #(ms f))))

(defn- verdict [times]
  (let [ratios (vec (map (fn [a b] (if (zero? a) 0.0 (/ b a))) (butlast times) (rest times)))
        worst  (if (seq ratios) (apply max ratios) 0.0)]
    [ratios worst]))

(defn- report [label times kind]
  (let [[ratios worst] (verdict times)
        v (case kind
            :per-op (cond (< worst 2.0) "O(1) per op" (< worst 6.0) "O(n) per op" :else "WORSE")
            :walk   (cond (< worst 6.0) "LINEAR" (< worst 11.0) "superlinear" :else "QUADRATIC  <-- BAD"))]
    (println (format "%-34s t=%-28s ratio=%-14s %s" label
                     (vec (map #(format "%.2f" %) times))
                     (vec (map #(format "%.1f" %) ratios)) v))))

(defn- S [n] (apply str (repeat n "x")))
(defn- U [n] (apply str (repeat n "\u00e9")))   ; 2-byte codepoints

(defn- per-op [label build run]
  (report label
          (vec (for [n SIZES]
                 (let [c (build n)]
                   (dotimes [_ 300] (run c))
                   (best-of 5 #(dotimes [_ OPS] (run c))))))
          :per-op))

(defn- walk [label build run]
  (report label
          (vec (for [n SIZES]
                 (let [c (build n)] (run c) (best-of 3 #(run c)))))
          :walk))

(println "=== string seq: fixed" OPS "ops per size, sizes" SIZES "===")
(per-op "(seq s) truthiness"        S (fn [s] (seq s)))
(per-op "(first (seq s))"           S (fn [s] (first (seq s))))
(per-op "(rest (seq s))"            S (fn [s] (rest (seq s))))
(per-op "(count ss) same seq"       (comp seq S) (fn [ss] (count ss)))
(per-op "(count ss) same seq, utf8" (comp seq U) (fn [ss] (count ss)))
(per-op "(count (rest ss))"         (comp seq S) (fn [ss] (count (rest ss))))

(println "\n=== whole walks ===")
(walk "loop next"                   S #(loop [s (seq %) n 0] (if s (recur (next s) (inc n)) n)))
(walk "loop next, count-guarded"    S #(loop [s (seq %) n 0] (if (> (count s) 1) (recur (next s) (inc n)) n)))
(walk "count-guarded, utf8"         U #(loop [s (seq %) n 0] (if (> (count s) 1) (recur (next s) (inc n)) n)))
(walk "reduce over (seq s)"         S #(reduce (fn [a _] (inc a)) 0 (seq %)))
(walk "into [] (seq s)"             S #(into [] (seq %)))
(walk "apply str (seq s)"           S #(apply str (seq %)))
(walk "frequencies"                 S #(frequencies %))
