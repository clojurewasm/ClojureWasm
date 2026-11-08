;; Allocation-every-1 regressions for the rooting gaps closed on 2026-09-25
;; (ADR-0197 shape: the launcher supplies CLJW_GC_TORTURE_ALLOC=1, the
;; assertions live here). Each case failed under alloc torture before its fix.
;;
;; Alloc torture only collects inside a live VM eval, so analysis-time cases
;; run through `eval`: analysis of a plain top-level form is never collected.

;; eval: the eval'd form's chunks lived in a per-call arena freed on return, so
;; a fn it def'd traced freed constant pools at the next collect.
(eval '(defn eg [x] (str "v=" x [x])))
(count (vec (range 50)))
(assert (= "v=3[3]" (eg 3)) "eval_defn_alloc_torture")

;; macro &form: the call list and its {:line :column} meta map sat in Zig
;; locals across the next alloc; the meta map was swept (traceArrayMap OOB).
(defmacro rooting-m [] :k)
(assert (= :k (eval '(do (def rooting-ep (rooting-m)) rooting-ep))) "macro_amp_form_meta_rooted")

;; map seq/keys/vals: the list builders had no fabrication bracket, so the
;; swept tail made (next (seq m)) loop back to the first entry.
(assert (= [:b 2] (second (seq {:a 1 :b 2}))) "map_seq_next")
(assert (= 6 (count (loop [s (seq {:a 1 :b 2 :c 3 :d 4 :e 5 :f 6}) acc []]
                      (if s (recur (next s) (conj acc (first s))) acc))))
        "map_seq_walk")
(assert (= [[:a :b] [1 2]] [(vec (keys {:a 1 :b 2})) (vec (vals {:a 1 :b 2}))]) "map_keys_vals")

;; sorted map/set: unrooted rebuilt nodes, fold accumulators and walks.
(assert (= 1 (count (sorted-set 1))) "sorted_set_count")
(assert (= [[1 :a] [2 :b] [3 :c]] (vec (seq (sorted-map 3 :c 1 :a 2 :b)))) "sorted_map_seq")
(assert (= [3 2 1] (vec (rseq (sorted-set 3 1 2)))) "sorted_set_rseq")
(assert (= [0 1 2 3 4 6 8 9 10 12 13 14 15 16 17 18 19]
           (vec (disj (into (sorted-set) (range 20)) 5 7 11)))
        "sorted_disj")
(assert (= [11 10 9 8 7 6 5 2 1 0]
           (vec (keys (dissoc (into (sorted-map-by (fn [a b] (compare b a)))
                                    (map vector (range 12) (range 12)))
                              3 4))))
        "sorted_by_dissoc")
(assert (= [[16 16] [17 17] [18 18] [19 19]]
           (vec (subseq (into (sorted-map) (map vector (range 20) (range 20))) > 15)))
        "sorted_subseq")

;; java.io.File .list/.listFiles: the result vector sat in a Zig local across
;; each child string/File alloc, so a collection swept it and the harness's
;; suite discovery saw 0 files ([CLJW-ALLOC-HARNESS]).
(let [expected (count (.list (java.io.File. "test/clj/torture")))]
  (assert (pos? expected) "file_list_nonempty")
  (assert (= expected (count (eval '(.list (java.io.File. "test/clj/torture"))))) "file_list_rooted")
  (assert (= expected (count (eval '(.listFiles (java.io.File. "test/clj/torture")))))
          "file_list_files_rooted"))

(println "PASS rooting_regressions_allocation: 15 assertions")
