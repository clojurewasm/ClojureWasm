;; `(seq v)` / `(rest v)` / `(next v)` over a vector are an `.array_seq` VIEW
;; (runtime/collection/array_seq.zig, O-058) — not the eager PersistentList
;; copy they used to build.
;;
;; The point of a view is that NOTHING observable may change: it prints as a
;; seq, is `=` to the list AND the vector with the same elements, hashes with
;; them, works as a map key, counts exactly, and terminates a `next` walk at
;; the same place. A representation swap that changes any of those is a bug,
;; not an optimisation — this suite pins the observable surface; the timing
;; claim lives in .dev/optimizations.md (O-058).
;;
;; Migrated from test/e2e/vector_seq_view.sh; each assertion keeps its bash
;; case name. ONE case did not move: `view_survives_gc_torture` needs
;; CLJW_GC_TORTURE=1 set on the PROCESS, which a suite running inside cljw
;; cannot do, so it stays in the e2e tier.
(ns suites.vector-seq-view-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest a-vector-seq-presents-as-a-seq
  (is (= '(1 2 3) (seq [1 2 3])))                    ; seq_prints_as_list
  (is (= '(2 3) (rest [1 2 3])))                     ; rest_prints_as_list
  (is (= '(2 3) (next [1 2 3])))                     ; next_prints_as_list
  (is (= "(1 2)" (pr-str (seq [1 2]))))              ; pr_str_is_seq_form
  (is (= "(1 2)" (str (seq [1 2]))))                 ; str_is_seq_form
  (is (true? (seq? (seq [1 2]))))                    ; is_seq
  (is (true? (sequential? (seq [1 2]))))             ; is_sequential
  (is (true? (coll? (seq [1 2]))))                   ; is_coll
  (is (false? (vector? (seq [1 2])))))               ; not_vector

;; AD: the class NAME is the reserved A14 slot name, and diverges from clj's
;; PersistentVector$ChunkedSeq. Only the name differs — every predicate,
;; equality, hash, print form, nth and count below matches clj.
(deftest the-class-name-is-the-reserved-slot-name
  (is (= "ArraySeq" (str (class (seq [1 2]))))))     ; class_name

(deftest metadata
  (is (= {:a 1} (meta (with-meta (seq [1 2]) {:a 1}))))          ; with_meta_round_trips
  (is (= '(1 2) (with-meta (seq [1 2]) {:a 1})))                 ; with_meta_keeps_value
  (is (true? (= (with-meta (seq [1 2]) {:a 1}) (list 1 2))))     ; with_meta_keeps_equality
  (is (true? (nil? (meta (seq [1 2])))))                         ; meta_is_nil_by_default
  (testing "meta does not ride along to the rest"
    (is (true? (nil? (meta (rest (with-meta (seq [1 2 3]) {:a 1})))))))) ; meta_does_not_propagate_to_rest

(deftest empty-of-a-seq-is-the-empty-list
  (is (= '() (empty (seq [1 2]))))                   ; empty_of_view
  (is (= '() (empty (range 3))))                     ; empty_of_range
  (is (= '() (empty (map inc [1 2]))))               ; empty_of_lazy_seq
  (is (= '() (empty (list 1 2)))))                   ; empty_of_list

(deftest walk-termination
  (is (true? (nil? (seq []))))                       ; seq_of_empty_is_nil
  (is (true? (nil? (next [1]))))                     ; next_of_one_is_nil
  (is (= '() (rest [1])))                            ; rest_of_one_is_empty
  (is (true? (empty? (rest [1]))))                   ; rest_of_one_is_seq
  (is (= '(1) (seq [1])))                            ; seq_of_one
  (is (true? (nil? (next (next [1 2])))))            ; next_walks_off_end
  (testing "a next walk visits each element exactly once"
    (is (= [1 2 3 4 5]
           (loop [s (seq [1 2 3 4 5]) acc []]
             (if s (recur (next s) (conj acc (first s))) acc)))))) ; next_walk_visits_each_once

(deftest equality-across-representations
  (is (true? (= (seq [1 2 3]) (list 1 2 3))))        ; eq_to_list
  (is (true? (= (seq [1 2 3]) [1 2 3])))             ; eq_to_vector
  (is (true? (= (list 1 2 3) (seq [1 2 3]))))        ; list_eq_to_view
  (is (true? (= (seq [1 2 3]) (seq [1 2 3]))))       ; eq_to_other_view
  (is (true? (= (rest [1 2 3]) (list 2 3))))         ; rest_eq_to_list
  (testing "and it still discriminates"
    (is (false? (= (seq [1 2 3]) (list 1 2 4))))     ; neq_on_content
    (is (false? (= (rest [1 2 3]) (list 1 2 3))))    ; neq_on_length
    (is (false? (= (seq [1 2]) (list 1 2 3))))))     ; neq_prefix

(deftest hashing-and-use-as-a-key
  (is (true? (= (hash (seq [1 2 3])) (hash [1 2 3]))))          ; hash_matches_vector
  (is (true? (= (hash (seq [1 2 3])) (hash (list 1 2 3)))))     ; hash_matches_list
  (is (= :v (get {(seq [1 2]) :v} (list 1 2))))                 ; view_as_map_key
  (is (= :v (get {(list 1 2) :v} (seq [1 2]))))                 ; list_key_found_by_view
  (is (= 1 (count #{(seq [1 2]) (list 1 2) [1 2]}))))           ; set_dedups_across_reprs

(deftest counting-and-indexed-access
  (is (= 4 (count (seq [1 2 3 4]))))                 ; count_full
  (is (= 3 (count (rest [1 2 3 4]))))                ; count_rest
  (is (= 2 (count (rest (rest [1 2 3 4])))))         ; count_nested
  (is (true? (counted? (seq [1 2]))))                ; counted
  (is (= 1 (first (seq [1 2 3]))))                   ; first
  (is (= 2 (first (rest [1 2 3]))))                  ; first_of_rest
  (is (= 2 (second (seq [1 2 3]))))                  ; second
  (is (= 3 (last (seq [1 2 3]))))                    ; last
  (is (= 2 (nth (seq [1 2 3]) 1)))                   ; nth
  (is (= 3 (nth (rest [1 2 3]) 1)))                  ; nth_offset
  (is (= :d (nth (seq [1 2]) 9 :d)))                 ; nth_default
  (testing "out-of-range nth without a default throws"
    (is (= :threw (try (nth (seq [1 2]) 9) :no-throw
                       (catch Exception _ :threw))))   ; nth_oob_throws
    (is (= :threw (try (nth (seq [1 2]) -1) :no-throw
                       (catch Exception _ :threw)))))) ; nth_negative_throws

(deftest it-flows-through-the-seq-library
  (is (= #{1 2 3} (into #{} (seq [1 2 3]))))              ; into_set
  (is (= [1 2 3] (vec (seq [1 2 3]))))                    ; vec_round
  (is (= '(2 3 4) (doall (map inc (seq [1 2 3])))))       ; map
  (is (= '(1 3) (doall (filter odd? (seq [1 2 3])))))     ; filter
  (is (= 6 (reduce + (seq [1 2 3]))))                     ; reduce
  (is (= 6 (apply + (seq [1 2 3]))))                      ; apply
  (is (= '(1 2 3) (sort (seq [3 1 2]))))                  ; sort
  (is (= '(3 2 1) (reverse [1 2 3])))                     ; reverse
  (is (= '(1 2 3) (concat (seq [1 2]) (seq [3]))))        ; concat
  (is (= '(0 1 2) (cons 0 (seq [1 2]))))                  ; cons_onto
  (is (= '(1 2) (seq (seq [1 2]))))                       ; seq_of_seq
  (is (= '(1 2) (take 2 (seq [1 2 3]))))                  ; take
  (is (= '(3 4) (drop 2 [1 2 3 4])))                      ; drop
  (is (= '((1 2) (3 4)) (partition 2 [1 2 3 4]))))        ; partition

(deftest nested-values-are-untouched
  (is (= '([1 2] {:a 1}) (seq [[1 2] {:a 1}])))           ; nested_print
  (is (true? (= (seq [[1 2]]) (list [1 2])))))            ; nested_eq

;; the view is O(1)/step; these are the regression guard against the eager
;; copy returning, not timing assertions (the numbers live in O-058)
(deftest it-scales
  (is (= 5000 (count (seq (vec (range 5000))))))                        ; large_count
  (is (= 4999 (count (rest (vec (range 5000))))))                       ; large_rest_count
  (is (= 4999 (last (seq (vec (range 5000))))))                         ; large_last
  (is (= 12497500 (reduce + 0 (seq (vec (range 5000))))))               ; large_walk_sum
  (is (= 4001 (nth (rest (vec (range 5000))) 4000)))                    ; large_nth
  (is (true? (= (seq (vec (range 1000))) (apply list (range 1000))))))  ; large_eq

;; a view holds its backing alive: allocate hard while a seq is live, then
;; read through it. (The CLJW_GC_TORTURE variant needs the env var set on the
;; process, so it stays in test/e2e/vector_seq_view.sh.)
(deftest the-view-keeps-its-backing-alive
  (is (= [200 0 199]
         (let [s (seq (vec (range 200)))]
           (dotimes [_ 200] (vec (range 200)))
           [(count s) (first s) (last s)]))))                           ; view_survives_gc
