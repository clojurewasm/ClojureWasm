;; Chunk-preserving map / filter / keep + chunked reduce / count
;; (§9.2.S D-163 / ADR-0065).
;;
;; map/filter/keep over a chunked source (a range seq) emit a `chunked_cons`
;; in the JVM chunk-cons shape, so the per-element lazy-seq machinery is
;; amortised 32x; reduce and count drain a whole chunk per step.
;;
;; The chunk size is 32, so the counts below straddle the boundary on purpose:
;; 1 (partial), 32 (exact), 33 (one over), 65 (two chunks plus one).
;; Chunking must never change WHAT is produced, only how often the lazy
;; machinery runs, and it must not over-realise a lazy source.
;;
;; Migrated from test/e2e/phase14_chunked_seq.sh; each assertion keeps its
;; bash case name.
(ns suites.chunked-seq-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest counts-straddle-the-chunk-boundary
  (is (= 1 (count (map inc (range 1)))))                    ; cnt_map_1
  (is (= 32 (count (map inc (range 32)))))                  ; cnt_map_32
  (is (= 33 (count (map inc (range 33)))))                  ; cnt_map_33
  (is (= 65 (count (map inc (range 65)))))                  ; cnt_map_65
  (is (= 1000 (count (map inc (range 1000))))))             ; cnt_map_1000

(deftest filter-keep-and-remove-chunk-too
  (is (= 500 (count (filter even? (range 1000)))))                          ; cnt_filt_1000
  (is (= 32 (count (keep (fn* [x] (if (even? x) x nil)) (range 64)))))      ; cnt_keep
  (is (= 32 (count (remove even? (range 64))))))                            ; cnt_remove

(deftest reduce-drains-a-chunk-per-step
  (is (= 5050 (reduce + (map inc (range 100)))))                            ; red_map
  (is (= 2500 (reduce + 0 (map inc (filter even? (range 100)))))))          ; red_nested

(deftest indexed-access-and-equality-are-unchanged
  (is (= 51 (nth (map inc (range 100)) 50)))                ; nth_map
  (is (= 100 (last (map inc (range 100)))))                 ; last_map
  (is (true? (= (map inc (range 40)) (range 1 41)))))       ; eq_map_range

;; chunking must not over-realise: taking 5 from a million-element source, or
;; from an INFINITE one, must still terminate
(deftest chunking-does-not-defeat-laziness
  (is (= [1 2 3 4 5] (into [] (take 5 (map inc (range 1000000))))))  ; lazy_map_take
  (is (= [1 3 5 7 9] (into [] (take 5 (filter odd? (range))))))      ; lazy_filt_take
  (is (= 33 (count (into [] (map inc (range 33)))))))                ; into_map_33

;; a chunked_cons still PRINTS as an ordinary seq
(deftest a-chunked-cons-prints-as-a-seq
  (is (= "(0 1 2)" (str (seq (range 3)))))                  ; print_chunked_cons
  (is (= "(1 2 3 4)" (str (rest (range 5)))))               ; print_cc_rest
  (is (= "[(0 1 2)]" (pr-str [(seq (range 3))]))))          ; print_cc_nested

;; The seq of a vector is IChunkedSeq, as clj's PersistentVector$ChunkedSeq:
;; its chunk is the 32-element leaf holding the cursor, so map/filter over a
;; vector realize a leaf at a time. Values measured on clj/bb (ADR-0205): the
;; first element of (map f v) runs f over the whole first leaf; a cursor at 5
;; exposes the rest of that leaf (27). subvec and empty seqs are not chunked.
(deftest a-vector-seq-is-chunked-by-leaf
  (let [v (vec (range 70))
        log (atom 0)
        m (map (fn* [x] (swap! log inc) x) v)]
    (is (= 0 (first m)))
    (is (= 32 @log))                                          ; vec_map_first_realizes_leaf
    (reset! log 0)
    (is (= 5 (first (map (fn* [x] (swap! log inc) x) (drop 5 v)))))
    (is (= 27 @log))                                          ; vec_map_mid_leaf
    (is (true? (chunked-seq? (seq v))))                       ; vec_seq_chunked
    (is (false? (chunked-seq? (seq (subvec v 1 5)))))         ; subvec_not_chunked
    (is (= 38 (count (chunk-rest (seq v)))))                  ; vec_chunk_rest
    (is (= 38 (count (chunk-rest (next (seq v))))))           ; vec_chunk_rest_mid
    (is (= 2485 (reduce + (map inc v))))                      ; vec_reduce_map
    (is (= (range 1 71) (map inc v)))                         ; vec_map_eq
    (is (= (filter odd? (range 70)) (filter odd? v)))))       ; vec_filter_eq

;; Multi-coll map is UNCHUNKED in clj: one f call per realized node, even over
;; chunked sources, stopping at the shortest source (ADR-0205, O-062). Values
;; measured on bb.
(deftest multi-coll-map-is-unchunked
  (let [log (atom 0)
        m (map (fn* [a b] (swap! log inc) (+ a b)) (vec (range 70)) (range 100 170))]
    (is (= 100 (first m)))
    (is (= 1 @log))                                           ; map2_first_one_call
    (is (= '(100 102 104) (take 3 m)))
    (is (= 11830 (reduce + m)))
    (is (= 70 @log)))                                         ; map2_each_once
  (let [log (atom 0)
        m (map (fn* [a b c] (swap! log inc) [a b c]) [1 2 3] [4 5] (range))]
    (is (= '([1 4 0] [2 5 1]) (doall m)))
    (is (= 2 @log)))                                          ; map3_shortest
  (is (= '() (map + [1 2] nil)))                              ; map2_nil_source
  (is (= '(4 10 18) (map * [1 2 3] [4 5 6 7])))
  (is (= '(10 12 14) (take 3 (map + (range) (iterate inc 10)))))
  (is (thrown? Exception (doall (map (fn* [a b] (throw (ex-info "boom" {}))) [1] [2])))))
