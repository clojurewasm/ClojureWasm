(require '[medley.core :as m])
(println "medley loaded successfully")

;; Test basic functions
(println "find-first:" (m/find-first even? [1 3 5 4 6]))
(println "dissoc-in:" (m/dissoc-in {:a {:b 1 :c 2}} [:a :b]))
(println "map-vals:" (m/map-vals inc {:a 1 :b 2 :c 3}))
(println "map-keys:" (m/map-keys name {:a 1 :b 2}))
(println "filter-vals:" (m/filter-vals even? {:a 1 :b 2 :c 3}))
(println "filter-keys:" (m/filter-keys #{:a :c} {:a 1 :b 2 :c 3}))
(println "remove-vals:" (m/remove-vals even? {:a 1 :b 2 :c 3}))
(println "remove-keys:" (m/remove-keys #{:b} {:a 1 :b 2 :c 3}))
