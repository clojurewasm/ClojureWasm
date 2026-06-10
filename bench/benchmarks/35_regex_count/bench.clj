;; Regex: count digit-runs in a string via re-seq, 10000x.
(def s "a12b345c6789d0e")
(loop [i 0 r 0]
  (if (< i 10000)
    (recur (inc i) (count (re-seq #"\d+" s)))
    (println r)))
