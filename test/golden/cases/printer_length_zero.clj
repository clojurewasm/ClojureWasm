;; Truncation at index 0 — *print-length* 0 on a NON-empty collection, the one
;; input where the truncation marker is written with nothing before it and so
;; must carry no separator. An empty collection does not truncate at all.
;; Values pinned against JVM Clojure 1.12: [...] {...} #{...} (...) and [].
(binding [*print-length* 0]
  (prn [1 2 3]) (prn {:a 1 :b 2}) (prn #{1 2 3}) (prn '(1 2 3)) (prn (range 5)))
(binding [*print-length* 0]
  (prn []) (prn {}) (prn #{}) (prn '()))
(binding [*print-length* 0] (prn [[1 2] [3 4]]))
(binding [*print-length* 1] (prn [1 2 3]))
