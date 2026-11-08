;; Laziness is observable through side effects; the ORDER of these lines is
;; the contract, not just the final value.
(def xs (map (fn [x] (println "realising" x) (* x x)) [1 2 3]))
(println "defined")
(println "first" (first xs))
(println "all" (doall xs))
