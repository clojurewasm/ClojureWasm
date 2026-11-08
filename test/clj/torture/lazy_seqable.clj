;; Allocation-every-1 boundary probes (ADR-0197). Kept separate from loading
;; clojure.test/reify-heavy suites, whose allocation-torture startup has its
;; own rooting gaps. Full GC callback contracts live in lazy_seqable_gc_test.
;; The process launcher only supplies the GC mode; assertions stay in Clojure.

(let [source (reify clojure.lang.Seqable
               (seq [_] (seq (to-array ["a" "b" "c"]))))]
  (assert (= ["b" "c"] (vec (next source))) "fresh coercion next")
  (assert (= ["b" "c"] (vec (rest source))) "fresh coercion rest"))

(assert (= ["a" "b"]
           (vec (lazy-seq
                  (reify clojure.lang.Seqable
                    (seq [_] (seq (to-array ["a" "b"])))))))
        "fresh lazy body")

(let [iter (.iterator (java.util.ArrayList. ["a" "b"]))]
  (assert (= "a" (.next iter)) "fresh iterator first")
  (assert (= "b" (.next iter)) "fresh iterator second")
  (assert (false? (.hasNext iter)) "fresh iterator exhausted"))

(println "PASS lazy_seqable_allocation: 6 assertions")
