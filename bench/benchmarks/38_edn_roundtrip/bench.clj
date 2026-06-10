;; EDN round-trip: pr-str + read-string a nested structure, 10000x.
;; Eval-free reader (AD-026) + printer; cljw-only benchmark.
(def data {:name "cw" :nums [1 2 3] :nested {:a true :b nil}})
(loop [i 0 r nil]
  (if (< i 10000)
    (recur (inc i) (read-string (pr-str data)))
    (println (:name r))))
