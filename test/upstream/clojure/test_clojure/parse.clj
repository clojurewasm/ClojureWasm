;; Upstream: clojure/test/clojure/test_clojure/parse.clj
;; Upstream lines: 102
;; CLJW markers: 6

;; CLJW: removed (:require clojure.test.check ...) and (:import java.util.UUID) — not available
(ns clojure.test-clojure.parse
  (:require
   [clojure.test :refer :all]))

(deftest test-parse-long
  (are [s expected]
       (= expected (parse-long s))
    "100" 100
    "+100" 100
    "0" 0
    "+0" 0
    "-0" 0
    "-42" -42
    "9223372036854775807" Long/MAX_VALUE
    "+9223372036854775807" Long/MAX_VALUE
    "-9223372036854775808" Long/MIN_VALUE
    "077" 77) ;; leading 0s are ignored! (not octal)

  (are [s] ;; do not parse
       (nil? (parse-long s))
    "0.3" ;; no float
    "9223372036854775808" ;; past max long
    "-9223372036854775809" ;; past min long
    "0xA0" ;; no hex
    "2r010")) ;; no radix support

;; CLJW: test-gen-parse-long skipped — needs clojure.test.check (generative testing library)

(deftest test-parse-double
  (are [s expected]
       (= expected (parse-double s))
    "1.234" 1.234
    "+1.234" 1.234
    "-1.234" -1.234
    "+0" +0.0
    "-0.0" -0.0
    "0.0" 0.0
    "5" 5.0
    "Infinity" Double/POSITIVE_INFINITY
    "-Infinity" Double/NEGATIVE_INFINITY
    "1.7976931348623157E308" Double/MAX_VALUE
    "4.9E-324" Double/MIN_VALUE
    "1.7976931348623157E309" Double/POSITIVE_INFINITY  ;; past max double
    "2.5e-324" Double/MIN_VALUE  ;; past min double, above half minimum
    "2.4e-324" 0.0)  ;; below minimum double
  (is (Double/isNaN (parse-double "NaN")))
  (are [s] ;; nil on invalid string
       (nil? (parse-double s))
    "double" ;; invalid string
    "1.7976931348623157G309")) ;; invalid, but similar to valid

;; CLJW: test-gen-parse-double skipped — needs clojure.test.check (generative testing library)

;; CLJW: adapted — UUID/randomUUID replaced with hardcoded valid UUID string
(deftest test-parse-uuid
  (is (parse-uuid "550e8400-e29b-41d4-a716-446655440000"))
  (is (nil? (parse-uuid "BOGUS"))) ;; nil on invalid uuid string
  (are [s] ;; throw on invalid type (not string)
    ;; CLJW: adapted — Throwable → Exception
       (try (parse-uuid s) (is false) (catch Exception _ (is true)))
    123
    nil))

(deftest test-parse-boolean
  (is (identical? true (parse-boolean "true")))
  (is (identical? false (parse-boolean "false")))

  (are [s] ;; nil on invalid string
       (nil? (parse-boolean s))
    "abc"
    "TRUE"
    "FALSE"
    " true ")

  (are [s] ;; throw on invalid type (not string)
    ;; CLJW: adapted — Throwable → Exception
       (try (parse-boolean s) (is false) (catch Exception _ (is true)))
    nil
    false
    true
    100))

;; CLJW-ADD: test runner invocation
(run-tests)
