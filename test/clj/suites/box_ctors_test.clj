;; The deprecated primitive-wrapper constructors: `(Long. x)`, `(Integer. x)`,
;; `(Short. x)`, `(Byte. x)`, `(Double. x)`, `(Float. x)`, `(Character. c)`,
;; `(Boolean. x)`. Each answers the plain cljw value, never a box (ADR-0059),
;; so the result joins arithmetic, `=`, coercion and `str` like any other.
;; Expected values are JVM Clojure's (measured with `clojure -M`), except where
;; a test names an accepted divergence.
;;
;; Run by `test/clj/run_suites.clj`.
(ns suites.box-ctors-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string]))

(defn- thrown-class
  "The simple class name of what evaluating `f` throws, or :no-throw."
  [f]
  (try (f) :no-throw
       (catch Exception e (last (clojure.string/split (str (type e)) #"\.")))))

(deftest string-ctors-parse
  (is (= 5 (Long. "5") (Integer. "5") (Short. "5") (Byte. "5")))
  (is (= 1.5 (Double. "1.5") (Float. "1.5")))
  (is (true? (Boolean. "true")))
  (is (true? (Boolean. "TRUE")))
  (is (false? (Boolean. "yes"))))

(deftest value-ctors-are-identity
  (is (= 5 (Long. 5) (Integer. 5)))
  (is (= 1.5 (Double. 1.5) (Float. 1.5)))
  (is (= \a (Character. \a)))
  (is (true? (Boolean. true)))
  (is (false? (Boolean. nil)) "nil matches the String ctor: parseBoolean(null) is false"))

(deftest results-are-ordinary-values
  (is (= 8 (+ 1 (Integer. 7))))
  (is (= 7 (Long. 7)))
  (is (= 7 (int (Integer. 7))))
  (is (= "7" (str (Integer. 7))))
  (is (= "a" (str (Character. \a))))
  (is (= 9223372036854775807 (Long. Long/MAX_VALUE)) "a heap Long is still a Long"))

(deftest boolean-ctor-is-the-plain-value
  (testing "AD-073: (Boolean. \"false\") is false itself, so the false branch is taken"
    (is (identical? false (Boolean. "false")))
    (is (= :falsey (if (Boolean. "false") :truthy :falsey)))))

(deftest short-and-byte-take-in-range-integers
  (testing "cljw has no short/byte type (AD-069): (Short. (short 7)) is (Short. 7)"
    (is (= 7 (Short. (short 7)) (Short. 7)))
    (is (= 7 (Byte. (byte 7)) (Byte. 7))))
  (is (= "IllegalArgumentException" (thrown-class #(Short. 99999))))
  (is (= "IllegalArgumentException" (thrown-class #(Byte. 300))))
  (testing "Integer narrows the long and overflows, as clj's reflective call does"
    (is (= "ArithmeticException" (thrown-class #(Integer. 3000000000))))))

(deftest malformed-and-out-of-range-strings
  (is (= "NumberFormatException" (thrown-class #(Integer. "abc"))))
  (is (= "NumberFormatException" (thrown-class #(Short. "99999"))))
  (is (= "NumberFormatException" (thrown-class #(Byte. "300"))))
  (is (= "NumberFormatException" (thrown-class #(Double. "x")))))

(deftest unmatched-arguments
  (testing "clj finds no ctor for these argument types"
    (is (= "IllegalArgumentException" (thrown-class #(Long. 1.5))))
    (is (= "IllegalArgumentException" (thrown-class #(Integer. 1.5))))
    (is (= "IllegalArgumentException" (thrown-class #(Double. 5))))
    (is (= "IllegalArgumentException" (thrown-class #(Float. 5))))
    (is (= "IllegalArgumentException" (thrown-class #(Boolean. 1)))))
  (testing "Character has one (char) ctor, reached by casting: a String is a cast failure"
    (is (= "ClassCastException" (thrown-class #(Character. "a")))))
  (testing "the message names the class, as clj's does"
    (is (= "No matching ctor found for class java.lang.Double"
           (try (Double. 5) (catch Exception e (ex-message e)))))))
