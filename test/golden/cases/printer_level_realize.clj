;; The printer realizes lazy values before rendering, and skips that work below
;; the *print-level* cut — where nothing of the value is rendered anyway. These
;; pin that the skip is invisible: an unrealized value AT the cut still prints
;; `#`, and one just above it still prints by content.
;;
;; Verified against clj 1.12; every line below matches it exactly.
(prn (binding [*print-level* 1] (pr-str [(map inc [1 2 3])])))
(prn (binding [*print-level* 2] (pr-str [[(map inc [1 2 3])]])))
(prn (binding [*print-level* 1] (pr-str {:a (range 3)})))
(prn (binding [*print-level* 2] (pr-str {:a {:b (range 3)}})))
(prn (binding [*print-level* 3] (pr-str [[[(map inc [1 2])]]])))
;; Just above the cut: realized by content.
(prn (binding [*print-level* 2] (pr-str [(map inc [1 2 3])])))
(prn (binding [*print-level* 4] (pr-str {:a {:b (range 3)}})))
;; Unbounded: nested lazy in a map value inside a vector.
(prn (pr-str [{:a (map inc [1 2])} (range 3)]))
;; Both limits at once, over a lazy seq.
(prn (binding [*print-length* 2 *print-level* 2] (pr-str [[1 2 3 4] (range 9)])))
;; An infinite seq is bounded by *print-length* alone — the realize must stop.
(prn (binding [*print-length* 5] (pr-str (range))))
;; A vector that needs no realization is handed back unchanged, which must not
;; change what it prints, including its metadata under *print-meta*.
(prn (binding [*print-meta* true] (pr-str (with-meta [1 2] {:k :v}))))
(prn (pr-str [1 [2 [3 [4]]]]))
