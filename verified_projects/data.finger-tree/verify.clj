;; clojure.data.finger-tree — persistent finger trees (deftype over the full
;; clojure.lang host-interface stack: Seqable/ISeq/IPersistentStack/Indexed/
;; Counted/Associative/Reversible). Run by `cljw -M:verify` (-> verify/-main).
;; Unblocked by the D-422 fixes (self-returning-ISeq print + clj RT.count
;; Counted-vs-walk) — count/seq/conj/conjl/peek/pop/nth now all clj-correct.
;;
;; NOTE: asserts compare via `vec`/scalars, NOT `(= '(…) (seq tree))`. The
;; finger-tree's seq is a self-returning typed_instance ISeq; cljw's `=` does
;; not yet compare a literal list against a Sequential deftype element-wise
;; (D-427) — `(vec tree)` realizes a real vector, so these asserts prove the
;; same content without depending on that unfixed `=` path.
(ns verify
  (:require [clojure.data.finger-tree
             :refer [double-list counted-double-list conjl]]))

(defn -main [& _]
  ;; double-list: a deque — conj appends right, conjl appends left.
  (let [dl (double-list 1 2 3 4)]
    (assert (= 4 (count dl)))                    ; clj RT.count walks (not Counted)
    (assert (= [1 2 3 4] (vec dl)))
    (assert (= 1 (first dl)))
    (assert (= 4 (peek dl)))                     ; rightmost (IPersistentStack)
    (assert (= [1 2 3] (vec (pop dl)))))         ; pop drops the rightmost
  ;; conj (right) vs conjl (left), exercised as the upstream tests do.
  (assert (= [0 1 2 3 4] (vec (reduce conj (double-list) (range 5)))))
  (assert (= [4 3 2 1 0] (vec (reduce conjl (double-list) (range 5)))))
  ;; counted-double-list: declares Counted (O(1) count) + Indexed (nth).
  (let [cdl (counted-double-list 10 20 30)]
    (assert (= 3 (count cdl)))                   ; clj uses the Counted -count
    (assert (= 20 (nth cdl 1)))
    (assert (= [10 20 30] (vec cdl))))
  (println "OK data.finger-tree — count/vec/first/peek/pop/conj/conjl/nth"))
