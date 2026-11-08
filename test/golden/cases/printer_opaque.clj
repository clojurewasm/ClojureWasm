;; Values whose printed form is identity-bearing or type-bearing. These are the
;; ones most likely to drift silently when an internal representation changes.
(prn (type 1) (type 1.0) (type "s") (type :k) (type 's) (type nil))
(prn (type []) (type '()) (type {}) (type #{}) (type (range 3)) (type (map inc [1])))
(prn (type #"re") (type (atom 1)) (type #'prn) (type (fn [])))
(println (boolean (re-find #"a+" "caaat")))
(prn (re-find #"a+" "caaat") (re-seq #"[0-9]+" "a1b22c333"))
