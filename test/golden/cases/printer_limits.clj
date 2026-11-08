;; The *print-* control vars, including truncation.
(binding [*print-length* 3]
  (prn (range 10)) (prn [1 2 3 4 5]) (prn {:a 1 :b 2 :c 3 :d 4}) (prn #{1 2 3 4 5}))
(binding [*print-level* 2]
  (prn [1 [2 [3 [4]]]]) (prn {:a {:b {:c 1}}}))
(binding [*print-length* 2 *print-level* 1]
  (prn [[1 2 3] [4 5 6]]))
(binding [*print-readably* nil] (pr "a\nb") (println))
(prn (binding [*print-namespace-maps* true] (pr-str {:a/x 1 :a/y 2})))
(prn (binding [*print-namespace-maps* false] (pr-str {:a/x 1 :a/y 2})))
(binding [*print-meta* true] (prn (with-meta [1] {:k :v})))
