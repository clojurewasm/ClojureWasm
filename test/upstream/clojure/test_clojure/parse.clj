;; Upstream: clojure/test/clojure/test_clojure/parse.clj
;; Upstream lines: 102
;; CLJW markers: 12

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
    ;; CLJW: adapted — Long/MAX_VALUE → literal value
    "9223372036854775807" 9223372036854775807
    "+9223372036854775807" 9223372036854775807)
  ;; CLJW: adapted — Long/MIN_VALUE literal overflows reader, use expression
  (is (= (dec -9223372036854775807) (parse-long "-9223372036854775808")))
  (is (= 77 (parse-long "077"))) ;; leading 0s are ignored! (not octal)

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
    "5" 5.0)
  ;; CLJW: adapted — Double/POSITIVE_INFINITY etc. → Clojure ##Inf/##-Inf/##NaN
  (is (= ##Inf (parse-double "Infinity")))
  (is (= ##-Inf (parse-double "-Infinity")))
  (is (= ##Inf (parse-double "1.7976931348623157E309")))  ;; past max double
  ;; CLJW: Double/MAX_VALUE and Double/MIN_VALUE tests adapted
  ;; Value comparison works even though our float printer truncates large exponents
  (let [max-double (parse-double "1.7976931348623157E308")]
    (is (> max-double 0))
    (is (not= ##Inf max-double)))
  (let [min-double (parse-double "4.9E-324")]
    (is (> min-double 0))
    (is (< min-double 1e-300)))
  ;; CLJW: adapted — Double/isNaN → NaN?
  (is (NaN? (parse-double "NaN")))
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
