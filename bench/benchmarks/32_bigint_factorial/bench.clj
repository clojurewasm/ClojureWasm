;; Numeric tower: 100! via promoting *' (Long->BigInt), 1000x.
;; Prints the digit count of 100! (158) — a canonical value identical across
;; languages, so the cross-language comparison stays apples-to-apples.
;; Uses *' (promoting) so the same source runs on JVM Clojure / babashka too;
;; cljw's plain * auto-promotes as well (F-005), giving the same result.
(defn fact [n] (reduce *' (range 1 (inc n))))
(loop [i 0 r 1]
  (if (< i 1000)
    (recur (inc i) (fact 100))
    (println (count (str r)))))
