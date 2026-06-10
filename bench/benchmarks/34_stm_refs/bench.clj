;; STM: a 2-ref transaction (alter both) committed 50000 times.
;; Clojure-specific (software transactional memory); cljw-only benchmark.
(def a (ref 0))
(def b (ref 0))
(loop [i 0]
  (if (< i 50000)
    (do (dosync (alter a inc) (alter b + 2)) (recur (inc i)))
    (println [(deref a) (deref b)])))
