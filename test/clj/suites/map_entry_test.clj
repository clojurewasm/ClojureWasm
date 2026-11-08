;; test/e2e/phase14_map_entry.sh
;;
;; D-209 / clj-parity C4: a distinct MapEntry value (activates the reserved
;; F-004 Group-A `.map_entry` slot, ADR-0078). A MapEntry IS-A 2-vector in
;; every observable way (vector?/=/nth/count/seq/print/destructure) yet
;; `map-entry?`→true distinguishes it from a literal `[1 2]`; conj DROPS the
;; nature (→ plain vector). `class` prints the simple name "MapEntry" (AD-003).
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_map_entry.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.map-entry-test
  (:require [clojure.test :refer [deftest is]]))

(deftest map-entry-cases
  (is (= "true" (pr-str (map-entry? (first {:a 1})))) "me_q")
  (is (= "false" (pr-str (map-entry? [1 2]))) "me_q_vec")
  (is (= "true" (pr-str (vector? (first {:a 1})))) "me_vecq")
  (is (= "true" (pr-str (sequential? (first {:a 1})))) "me_seqq")
  (is (= "2" (pr-str (count (first {:a 1})))) "me_count")
  (is (= ":a" (pr-str (nth (first {:a 1}) 0))) "me_nth0")
  (is (= "1" (pr-str (nth (first {:a 1}) 1))) "me_nth1")
  (is (= ":a" (pr-str (key (first {:a 1})))) "me_key")
  (is (= "1" (pr-str (val (first {:a 1})))) "me_val")
  (is (= ":a" (pr-str (get (first {:a 1}) 0))) "me_get0")
  (is (= "\"[:a 1]\"" (pr-str (pr-str (first {:a 1})))) "me_pr")
  (is (= "[:a 1]" (pr-str (let [[k v] (first {:a 1})] [k v]))) "me_destr")
  (is (= "true" (pr-str (= (first {:a 1}) [:a 1]))) "me_eq_fwd")
  (is (= "true" (pr-str (= [:a 1] (first {:a 1})))) "me_eq_rev")
  (is (= "[:a 1 99]" (pr-str (conj (first {:a 1}) 99))) "me_conj")
  (is (= "false" (pr-str (map-entry? (conj (first {:a 1}) 99)))) "me_conj_q")
  (is (= "{:a 1, :b 2}" (pr-str (into {} (seq {:a 1 :b 2})))) "me_into")
  (is (= "\"MapEntry\"" (pr-str (str (class (first {:a 1}))))) "me_class"))
