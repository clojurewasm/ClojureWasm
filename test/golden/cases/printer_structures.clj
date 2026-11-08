;; Values with a dedicated print branch beyond the core collections.
(prn (conj clojure.lang.PersistentQueue/EMPTY 1 2 3))
(prn (sorted-map :b 2 :a 1) (sorted-set 3 1 2) (sorted-map-by > 1 :a 2 :b))
(prn (range 3) (range 0 10 2) (take 3 (iterate inc 0)))
(defrecord R [a b])
(prn (->R 1 2) (map->R {:a 1 :b 2}) (assoc (->R 1 2) :c 3))
(prn (ex-info "msg" {:k 1}))
(prn #'prn (find-ns 'clojure.core))
