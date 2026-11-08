;; AD-076: a string is a sequence of Unicode CODE POINTS in cljw, where JVM
;; Clojure exposes UTF-16 CODE UNITS. Every character outside the Basic
;; Multilingual Plane (emoji, rare CJK, most historic scripts) is one position
;; here and two (a surrogate pair) on the JVM.
;;
;; This suite PINS the cljw answers so the divergence cannot flip silently in
;; either direction: a change that starts counting UTF-16 units must remove the
;; AD-076 entry in .dev/accepted_divergences.yaml and rewrite these
;; assertions, deliberately. The clj answer is on each line's comment,
;; measured against JVM Clojure 1.12 (GitHub issue #1).
;;
;; The language surface (count, subs, nth, seq) and the interop surface
;; (.length, .charAt, .indexOf, .substring) follow the SAME model: cljw has one
;; string representation, UTF-8 indexed by code point, and does not keep a
;; second UTF-16 index for the interop methods.
(ns suites.string-code-point-test
  (:require [clojure.test :refer [deftest is testing]]))

(def globe "🌍") ; U+1F30D, a surrogate pair in UTF-16

(deftest count-is-in-code-points
  (is (= 1 (count globe)))            ; clj 2
  (is (= 3 (count "ab🌍")))           ; clj 4
  (testing "a BMP multibyte character is one position in both runtimes"
    (is (= 5 (count "héllo")))))

(deftest subs-and-nth-never-split-a-pair
  (is (= "🌍" (subs "a🌍b" 1 2)))     ; clj a lone high surrogate
  (is (= "b" (subs "a🌍b" 2 3)))      ; clj the low surrogate
  (is (= \b (nth "a🌍b" 2))))         ; clj the low surrogate

(deftest a-char-is-a-code-point
  (is (= [127757] (vec (map int globe))))  ; clj [55356 57101]
  (is (= "🌍" (str (first globe))))        ; clj a lone high surrogate
  (is (char? (first globe))))

(deftest interop-methods-follow-the-same-model
  (is (= 1 (.length globe)))                 ; clj 2
  (is (= \🌍 (.charAt "a🌍b" 1)))            ; clj \? (high surrogate)
  (is (= 2 (.indexOf "a🌍b" "b")))           ; clj 3
  (is (= "🌍" (.substring "a🌍b" 1 2))))     ; clj a lone high surrogate

(deftest where-the-two-runtimes-agree
  (testing "UTF-8 byte length is a byte count, not an index, so it matches"
    (is (= 4 (count (.getBytes globe "UTF-8")))))
  (testing "reverse keeps the pair whole in both (StringBuilder.reverse does too)"
    (is (= "b🌍a" (clojure.string/reverse "a🌍b")))))
