;; Regex surface (ADR-0031 cycle 1, capturing groups D-093, §A26 print sweep).
;;
;; The matcher is a Pike NFA, so it is ReDoS-immune on untrusted INPUT; the
;; INV-1 case below guards the remaining exposure, the compile side.
;;
;; Migrated from test/e2e/phase6_regex_cycle1.sh; each assertion keeps its bash
;; case name.
(ns suites.regex-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest re-find-matches-the-leftmost-occurrence
  (is (= "123" (re-find #"\d+" "abc123")))          ; cycle1_exit_smoke_re_find_digits
  (is (= "b" (re-find #"a|b" "xby")))               ; cycle1_alt
  (is (= "aaa" (re-find #"a*" "aaa")))              ; cycle1_star
  (is (= "def" (re-find #"[a-z]+" "ABCdef")))       ; cycle1_class_range
  (is (= "hello" (re-find #"\w+" " hello world "))))  ; cycle1_word_escape

(deftest re-matches-requires-the-WHOLE-string
  (is (= "123" (re-matches #"\d+" "123")))          ; cycle1_re_matches_full
  (testing "a partial match is nil, not the matched part"
    (is (nil? (re-matches #"\d+" "123abc")))))      ; cycle1_re_matches_partial_nil

(deftest anchors-and-re-pattern
  (is (= "abc" (re-find #"^abc$" "abc")))           ; cycle1_anchor_full
  (is (nil? (re-find #"^abc$" "xabc")))             ; cycle1_anchor_no_match
  (testing "re-pattern builds a regex re-find accepts"
    ;; the string literal "\\d" decodes to \d, which is what the compiler sees
    (is (= "9" (re-find (re-pattern "\\d") "x9y"))))) ; cycle1_re_pattern_round_trip

(deftest re-seq-yields-successive-non-overlapping-matches
  (is (= '("1" "22" "333") (re-seq #"\d+" "a1b22c333")))    ; reseq_nums
  (is (= '("ab" "cd" "ef") (re-seq #"[a-z]+" "ab cd ef")))  ; reseq_words
  (testing "no match is nil, not an empty seq"
    (is (nil? (re-seq #"\d+" "abc"))))                      ; reseq_none
  (testing "the re-find-from primitive returns [match start end]"
    (is (= ["22" 3 5] (re-find-from #"\d+" "a1b22" 2)))))   ; refindfrom

;; D-093: with capturing groups the result is [whole g1 …] instead of the
;; whole-match string
(deftest capturing-groups
  (is (= ["ab" "a" "b"] (re-find #"(\w)(\w)" "ab")))            ; group_re_find
  (is (= ["42" "4" "2"] (re-matches #"(\d)(\d)" "42")))         ; group_re_matches
  (testing "nested groups number outer-then-inner"
    (is (= ["42" "42" "4" "2"] (re-find #"((\d)(\d))" "42")))) ; group_nested
  (testing "a group that does not participate is nil"
    (is (= ["a" "a" nil] (re-find #"(a)(b)?" "a"))))            ; group_optional_nil
  (testing "(?:…) is non-capturing and skipped in the vector"
    (is (= ["ab" "b"] (re-find #"(?:\w)(\w)" "ab"))))           ; group_non_capturing
  (testing "greedy backtracking still finds the leftmost-greedy submatch"
    (is (= ["aaaa" "aaa" "a"] (re-matches #"(a+)(a+)" "aaaa")))) ; group_greedy
  (testing "re-seq yields one group vector per match"
    (is (= '(["12" "1" "2"] ["34" "3" "4"]) (re-seq #"(\d)(\d)" "1234")))) ; group_re_seq
  (testing "no groups still gives the whole-match string"
    (is (= "hi" (re-find #"\w+" "hi")))))                        ; group_none_string

;; pr/prn render the `#"…"` reader form (JVM print-method Pattern); str renders
;; the raw pattern (Pattern.toString)
(deftest printing-a-regex
  (is (= "#\"a.c\"" (pr-str (re-pattern "a.c"))))   ; regex_pr_reader_form
  (is (= "a.c" (str #"a.c"))))                      ; regex_str_raw

;; INV-1: a nested-counted-repetition compile bomb on untrusted PATTERN input
;; — `(a{65535}){65535}` would expand to ~4.3e9 instructions — must be a
;; catchable IllegalArgumentException, not an OOM or a process kill.
(deftest a-compile-bomb-is-catchable-not-fatal
  (is (= :caught
         (try (do (re-pattern "(a{65535}){65535}") :uncaught)
              (catch IllegalArgumentException _ :caught)))))  ; inv1_compile_bomb_catchable
