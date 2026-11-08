;; Maps ABOVE the ArrayMap->HAMT promotion boundary (16 entries), which the
;; printer walks with a different routine than the array form. 40 keys exceed
;; the 32 root slots, so the root carries child nodes and the walk recurses.
;; Keep the keys integers: their order is hash-determined, and integer hashing
;; is a pure function of the value, so this snapshot holds on every platform.
(def m (into {} (map (fn [i] [i (* i i)]) (range 40))))
(prn (count m))
(prn m)
(prn (into {} (map (fn [i] [i i]) (range 17))))
(binding [*print-length* 5] (prn m))
(binding [*print-level* 1] (prn (into {} (map (fn [i] [i {:v i}]) (range 20)))))
