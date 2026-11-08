;; `(seq s)` over a string is an O(1)-per-step byte-offset VIEW
;; (runtime/collection/string_seq.zig, `.string_seq` tag, D-179 / O-060) — not
;; the eager n-cell codepoint cons chain it used to build. The old path asked
;; `codepointAt(s, i)` per element, restarting a UTF-8 walk from byte 0 every
;; time, so building the seq was O(n^2).
;;
;; A StringSeq is an ordinary seq of characters: NOTHING observable may change
;; versus the eager char list of the same string. It prints as `(\a \b)`, is
;; `seq?`/`sequential?`, and is `=`/hash-equal to both the char list and the
;; char vector (including as a map key or set member).
;;
;; Migrated from test/e2e/string_seq_view.sh; each assertion keeps its bash
;; case name. Contents assert value equality; the two cases that are ABOUT
;; representation keep pr-str/str.
(ns suites.string-seq-view-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest a-string-seq-is-an-ordinary-seq
  (is (= '(\h \e \l \l \o) (seq "hello")))          ; basic
  (is (true? (seq? (seq "ab"))))                    ; is_seq
  (is (true? (sequential? (seq "ab"))))             ; sequential
  (is (true? (coll? (seq "ab"))))                   ; coll
  (is (false? (string? (seq "ab"))))                ; not_string
  (is (false? (vector? (seq "ab")))))               ; not_vector

(deftest it-presents-as-a-char-seq
  (is (= "(\\a \\b)" (pr-str (seq "ab"))))          ; pr_str
  (testing "though its class names the view"
    (is (= "StringSeq" (str (class (seq "ab")))))))  ; class_name

;; the whole point of the view: stepping is by BYTE OFFSET, so multi-byte
;; codepoints must still count and index as single characters
(deftest utf8-is-walked-by-codepoint
  (is (= 5 (count (seq "héllo"))))                  ; utf8_count
  (is (= \c (first (seq "café"))))                  ; utf8_first
  (is (= '(\a \f \é) (rest (seq "café"))))          ; utf8_rest
  (is (= \ö (nth (vec (seq "wörld")) 1)))           ; utf8_nth
  (is (= \d (last (seq "wörld")))))                 ; utf8_last

(deftest the-seq-accessors
  (is (= \c (first (seq "café"))))                  ; first
  (is (= \b (second (seq "abc"))))                  ; second
  (is (= \d (last (seq "abcd"))))                   ; last
  (is (= '(\a \f \é) (rest (seq "café"))))          ; rest
  (is (= '(\b) (next (seq "ab"))))                  ; next
  (testing "next of a one-element seq is nil"
    (is (nil? (next (seq "a")))))                   ; next_single
  (is (= \b (fnext (seq "abc"))))                   ; fnext
  (is (= '(\c \d \e) (nthrest (seq "abcde") 2)))    ; nthrest
  (is (= 3 (count (seq "abc"))))                    ; count
  (is (= 2 (count (rest (seq "abc"))))))            ; count_rest

(deftest value-semantics-match-the-eager-char-collections
  (is (true? (= (seq "ab") (list \a \b))))                        ; eq_list
  (is (true? (= (seq "ab") [\a \b])))                             ; eq_vector
  (is (true? (= (hash (seq "ab")) (hash [\a \b]))))               ; hash_vector
  (is (true? (= (hash (seq "ab")) (hash (list \a \b)))))          ; hash_list
  (is (= :x (get {(seq "ab") :x} (list \a \b))))                  ; map_key
  (is (= 1 (count (hash-set (seq "ab") [\a \b]))))                ; set_dedup
  (testing "a longer string is not equal"
    (is (false? (= (seq "ab") (seq "abc"))))))                    ; neq_short

(deftest it-flows-through-the-seq-library
  (is (= [\a \b \c] (vec (seq "abc"))))                    ; vec
  (is (= [\a \b] (into [] (seq "ab"))))                    ; into
  (is (= "abc" (apply str (seq "abc"))))                   ; apply_str
  (is (= '(\c \b \a) (reverse (seq "abc"))))               ; reverse
  (is (= '(\a \b) (take 2 (seq "abcde"))))                 ; take
  (is (= '(\c \d \e) (drop 2 (seq "abcde"))))              ; drop
  (is (= '(\x \a \b) (cons \x (seq "ab"))))                ; cons
  (is (= '(\a \b \c \d) (concat (seq "ab") (seq "cd"))))   ; concat
  (is (= '(65 66) (map int (seq "AB"))))                   ; map_int
  (is (= '(66 67) (map inc (map int (seq "AB")))))         ; map_map
  (is (= '(\a \c) (filter #(not= % \b) (seq "abc"))))      ; filter
  (is (= "abc" (reduce str "" (seq "abc")))))              ; reduce

(deftest boundaries
  (testing "an empty string seqs to nil, as any empty coll does"
    (is (nil? (seq ""))))                                  ; empty_nil
  (is (false? (empty? (seq "a"))))                         ; empty_pred
  (is (= \d (first (drop 3 (seq "abcde"))))))              ; drop_past

;; the O(n^2) walk this view replaced made these hang; they are the
;; regression guard, not a timing assertion (the numbers live in O-060)
(deftest it-scales
  (is (= 20000 (count (seq (apply str (repeat 20000 "x"))))))     ; scale_count
  (is (= 10000 (count (seq (apply str (repeat 10000 "é")))))))    ; scale_utf8
