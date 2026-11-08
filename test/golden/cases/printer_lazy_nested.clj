;; Lazy seqs held INSIDE collections, which the printer realizes in place
;; before rendering. Each line puts the lazy seq somewhere a different branch
;; of the realize walk has to reach: map value, sorted-map value, vector
;; element, nested map, map entry.
;;
;; The `nil` key is a boundary probe, not decoration: the walk over a map's
;; keys ends on the empty list, whose `first` is nil, so a walk that ran one
;; iteration too long would look up exactly this key. With nil absent the
;; overrun is invisible; with it present and holding a lazy value, any
;; difference has somewhere to show.
;;
;; Values pinned against JVM Clojure 1.12.
(prn {:a (map inc [1 2 3]) :b [4 5]})
(prn {nil (map inc [1 2 3])})
(prn (sorted-map :a (map inc [1 2 3]) :b 2))
(prn [(map inc [1 2]) (filter odd? (range 6))])
(prn {:a {:b (map inc [1 2])}})
(prn (first {:k (map inc [1 2])}))
(prn #{[(map inc [1 2])]})
(binding [*print-length* 2] (prn {:a (map inc (range 10))}))
