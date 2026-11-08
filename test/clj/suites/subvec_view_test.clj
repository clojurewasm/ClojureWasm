;; `(subvec v start end)` is an O(1) shared-structure VIEW
;; (runtime/collection/sub_vector.zig, `.sub_vector` tag, D-583 / O-059) — not
;; the eager `(into [] (take … (drop …)))` copy it used to build.
;;
;; A subvec is a first-class IPersistentVector: NOTHING observable may change
;; versus a materialized vector of the same elements. It prints as `[..]`, is
;; `vector?`, is `=`/hash-equal to the plain vector (including as a map key),
;; counts exactly, supports nth/conj/assoc/pop/peek/seq/rseq/reduce, carries
;; meta, and flattens when nested. A representation swap that changes any of
;; those is a bug, not an optimisation — this suite pins the observable
;; surface; the timing claim lives in .dev/optimizations.md (O-059).
;;
;; Migrated from test/e2e/subvec_view.sh; each assertion keeps its bash case
;; name. Contents assert value equality; the two cases that are specifically
;; ABOUT representation keep pr-str/str.
(ns suites.subvec-view-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.walk :as walk]))

(deftest a-subvec-is-a-vector
  (is (= [2 3 4 5 6] (subvec (vec (range 10)) 2 7)))       ; basic
  (is (true? (vector? (subvec [1 2 3] 0 2))))              ; is_vector
  (is (false? (seq? (subvec [1 2 3] 0 2))))                ; not_seq
  (is (true? (coll? (subvec [1 2 3] 0 2))))                ; coll
  (is (true? (counted? (subvec [1 2 3] 0 2))))             ; counted
  (is (true? (sequential? (subvec [1 2 3] 0 2))))          ; sequential
  (is (true? (associative? (subvec [1 2 3] 0 2))))         ; associative
  (is (true? (indexed? (subvec [1 2 3] 0 2))))             ; indexed
  (is (true? (reversible? (subvec [1 2 3] 0 2))))          ; reversible
  (is (true? (ifn? (subvec [1 2 3] 0 2)))))                ; ifn

(deftest it-presents-as-a-vector
  (is (= "[1 2]" (pr-str (subvec [1 2 3] 0 2))))           ; pr_str_is_vec
  (testing "though its class names the view"
    (is (= "SubVector" (str (class (subvec [1 2] 0 2)))))))  ; class_name

(deftest indexed-access
  (is (= 5 (count (subvec (vec (range 10)) 2 7))))         ; count
  (is (= 3 (nth (subvec (vec (range 10)) 2 7) 1)))         ; nth
  (is (= 3 (get (subvec (vec (range 10)) 2 7) 1)))         ; get
  (is (true? (contains? (subvec [1 2 3] 0 2) 1)))          ; contains_idx
  (is (false? (contains? (subvec [1 2 3] 0 2) 5)))         ; contains_oob
  (testing "and it is callable on its own index"
    (is (= 20 ((subvec [10 20 30] 0 2) 1))))               ; fn_invoke
  (is (= 2 (first (subvec [1 2 3 4] 1 3))))                ; first
  (is (= 3 (last (subvec [1 2 3 4] 1 3))))                 ; last
  (is (= 3 (peek (subvec [1 2 3 4] 1 3))))                 ; peek
  (is (= :threw (try (nth (subvec [1 2 3] 0 2) 5)
                     (catch Exception e :threw)))))        ; nth_oob_throws

(deftest updates-produce-plain-vectors-and-leave-the-parent-alone
  (is (= [2 3 4 5 6 99] (conj (subvec (vec (range 10)) 2 7) 99)))     ; conj
  (is (= [-1 3 4 5 6] (assoc (subvec (vec (range 10)) 2 7) 0 -1)))    ; assoc
  (is (= [2 3 4 5 6 77] (assoc (subvec (vec (range 10)) 2 7) 5 77)))  ; assoc_append
  (is (= [2 3 4 5] (pop (subvec (vec (range 10)) 2 7))))              ; pop
  (is (= [] (pop (subvec [1 2 3] 1 2))))                             ; pop_to_empty
  (is (true? (vector? (conj (subvec [1 2 3] 0 2) 9))))               ; conj_still_vec
  (testing "the shared parent is untouched"
    (is (= [0 1 2 3 4]
           (let [v (vec (range 5)) s (subvec v 1 4)] (conj s 99) v))))) ; parent_shared_untouched

(deftest subvecs-nest
  (is (= [7 8 9 10] (subvec (subvec (vec (range 20)) 5 15) 2 6)))     ; nested
  (is (true? (vector? (subvec (subvec [1 2 3 4 5] 1 5) 1 3)))))       ; nested_vec

(deftest the-seq-surface
  (is (= '(2 3) (seq (subvec [1 2 3 4] 1 3))))             ; seq
  (is (= '(3 2 1) (rseq (subvec [1 2 3 4] 0 3))))          ; rseq
  (is (= '(3 4) (rest (subvec [1 2 3 4] 1 4))))            ; rest
  (is (= '(3 4) (map inc (subvec [1 2 3 4] 1 3))))         ; map_over
  (is (= 5 (reduce + (subvec [1 2 3 4] 1 3))))             ; reduce
  (is (= [1 2] (into [] (subvec [1 2 3] 0 2))))            ; into_vec
  (is (= {:a 1} (into {} [(subvec [:a 1] 0 2)])))          ; into_map
  (is (= [1 2] (walk/postwalk identity (subvec [1 2 3] 0 2))))) ; walk

;; equality and hashing must be indistinguishable from the plain vector,
;; including when used as a map key or a set member
(deftest value-semantics-match-a-plain-vector
  (is (true? (= (subvec [1 2 3] 0 2) [1 2])))                        ; eq_plain
  (is (true? (= (subvec [1 2 3] 0 2) (list 1 2))))                   ; eq_list
  (is (true? (= (hash (subvec [1 2 3] 0 2)) (hash [1 2]))))          ; hash_eq
  (is (= :x (get {(subvec [1 2 3] 0 2) :x} [1 2])))                  ; map_key_lookup
  (is (= 0 (compare (subvec [1 2] 0 2) [1 2])))                      ; compare
  (is (= 1 (count (hash-set (subvec [1 2 3] 0 2) [1 2]))))           ; set_dedup
  (is (= {:m 1} (meta (with-meta (subvec [1 2 3] 0 2) {:m 1})))))    ; with_meta

(deftest boundary-ranges
  (is (= [] (subvec [1 2 3] 1 1)))                         ; empty_range
  (is (= [] (empty (subvec [1 2 3] 0 2))))                 ; empty_of
  (is (= [1 2 3] (subvec [1 2 3] 0 3)))                    ; full_range
  (is (true? (vector? (subvec [1 2 3] 0 3))))              ; full_range_vec
  (testing "out-of-bounds bounds throw"
    (is (= :threw (try (subvec [1 2 3] 0 5) (catch Exception e :threw))))  ; oob_throws
    (is (= :threw (try (subvec [1 2 3] -1 2) (catch Exception e :threw)))))) ; oob_neg_throws
