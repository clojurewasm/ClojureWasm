;; D-217: a String is Indexed. clj treats a String as Indexed (nth),
;; index-gettable (get) and index-bounds-testable (contains?), indexing by
;; char. cljw indexes by CODEPOINT, which matches the JVM char for ASCII and
;; for multibyte BMP characters alike.
;;
;; Migrated from test/e2e/phase14_string_indexed.sh (23 cases). Six of those
;; were "does the process exit non-zero" checks:
;;   "$BIN" -e '(subs "hello" 2 10)' >/dev/null 2>&1 && fail ... || true
;; which passes if the process dies for ANY reason. All six raise catchable
;; index errors (verified 2026-09-09), so they now assert the message.
(ns suites.string-indexed-test
  (:require [clojure.test :refer [deftest is]]))

;; --- nth: the codepoint char at an index, with a default or a throw when out
;; of range ---

(deftest nth-by-index
  (is (= \a (nth "abc" 0)))
  (is (= \c (nth "abc" 2))))

(deftest nth-with-default-out-of-range
  (is (= :default (nth "abc" 5 :default)))
  (is (= :neg (nth "abc" -1 :neg))))

;; Indexing is by codepoint, so a multibyte character is ONE position.
(deftest nth-indexes-by-codepoint
  (is (= \é (nth "héllo" 1))))

;; Without a default, nth throws (clj StringIndexOutOfBounds parity).
(deftest nth-out-of-range-throws
  (is (thrown-with-msg? Throwable #"nth: index out of range" (nth "abc" 5))))

;; --- get: the codepoint char, else the default. Out of range or a
;; non-integer key yields the default rather than throwing, which is where get
;; differs from nth. ---

(deftest get-by-index
  (is (= \a (get "abc" 0))))

(deftest get-out-of-range-is-nil-or-default
  (is (nil? (get "abc" 10)))
  (is (= :x (get "abc" 10 :x)))
  (is (= :y (get "abc" -1 :y))))

;; --- contains? on a string is an INDEX-BOUNDS test, not char membership ---

(deftest contains-tests-index-bounds
  (is (= [true true false false] [(contains? "abc" 0)
                                  (contains? "abc" 2)
                                  (contains? "abc" 3)
                                  (contains? "abc" -1)])))

(deftest contains-on-empty-string
  (is (false? (contains? "" 0))))

;; --- subs is codepoint-based, and clj bounds-checks rather than clamping ---

(deftest subs-basic
  (is (= "ll" (subs "hello" 2 4)))
  (is (= "hello" (subs "hello" 0 5))))

;; start == length is legal and yields the empty string.
(deftest subs-start-at-length-is-empty
  (is (= "" (subs "hello" 5))))

(deftest subs-slices-by-codepoint
  (is (= "él" (subs "héllo" 1 3))))

;; Past the end, before the start, inverted, or negative: all throw. cljw
;; raises an index error rather than returning a clamped substring.
(deftest subs-out-of-bounds-throws
  (is (thrown-with-msg? Throwable #"subs: index out of range" (subs "hello" 2 10)))
  (is (thrown-with-msg? Throwable #"subs: index out of range" (subs "hello" 6)))
  (is (thrown-with-msg? Throwable #"subs: index out of range" (subs "hello" 3 2)))
  (is (thrown-with-msg? Throwable #"subs: index out of range" (subs "hello" -1))))
