;; Sets ABOVE the array-set->HAMT promotion boundary (8 elements). 40 elements
;; exceed the 32 root slots, so the root carries child nodes and the walk
;; recurses. The separator between set elements is " ", where a map's is ", " —
;; both come from the same walk, so this file is what pins the set half of it.
;; Keep the elements integers, per printer_hamt_map.clj.
(def s (into #{} (range 40)))
(prn (count s))
(prn s)
(prn (into #{} (range 9)))
(binding [*print-length* 4] (prn s))
