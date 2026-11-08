;; A Sequential deftype ISeq whose -next hands back a LAZY tail, printed several
;; ways. This is the mutation-killing pin for print.zig's two realization-stratum
;; survivors: the *print-length* cutoff and the instance-seq lazy-tail drain loop.
;; A custom ISeq instance forces the printer through realizeInstanceSeq, whose
;; -next returns a non-instance lazy seq that the walk must then drain (the tail
;; loop) while honouring *print-length* (the cutoff). Bare lazy seqs never reach
;; that instance branch, so only a deftype ISeq exercises it.
;;
;; Values pinned against JVM Clojure 1.12.
(deftype LT [h t]
  clojure.lang.Sequential
  clojure.lang.Seqable
  (seq [this] this)
  clojure.lang.ISeq
  (first [this] h)
  (next [this] t)
  (more [this] (if (nil? t) '() t))
  (cons [this x] (cons x this)))

;; instance walk whose tail is a lazy seq → drains the tail loop
(prn (LT. 1 (map inc [1 2 3])))
;; a lazy head element + a filtered lazy tail, both realized in one instance walk
(prn (LT. (map inc [9]) (filter odd? (range 6))))
;; *print-length* cutoff on the instance tail
(binding [*print-length* 2] (prn (LT. 0 (map inc (range 10)))))
;; INFINITE lazy tail that only terminates because the cutoff is honoured
(binding [*print-length* 3] (prn (LT. 0 (map inc (iterate inc 0)))))
;; the same cutoff on a bare lazy seq, crossing the truncation boundary
(binding [*print-length* 3] (prn (map inc (iterate inc 0))))
;; -next nil skips the tail branch
(prn (LT. :only nil))
