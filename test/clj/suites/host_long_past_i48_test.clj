;; Value.initInteger encodes an i64 outside the i48 fixnum window as an f64,
;; so a host surface that hands a raw large i64 to it returns a Double that
;; fails (= x Long/MAX_VALUE). 61049014 fixed Runtime.maxMemory by routing
;; past-i48 values through big_int.allocFromI64(.long). This suite pins every
;; other host surface that can return a large integer: each one must answer
;; class Long, and the past-i48 ones must round-trip their exact value.
;; Detection is (str (class x)); a "Double" here is the trap.
(ns suites.host-long-past-i48-test
  (:require [clojure.test :refer [deftest is testing]]))

(defn- exact [x want] [(str (class x)) (= x want)])

(deftest clocks-answer-long
  (is (= "Long" (str (class (System/currentTimeMillis)))) "currentTimeMillis")
  (is (= "Long" (str (class (System/nanoTime)))) "nanoTime")
  (is (= "Long" (str (class (.toEpochMilli (java.time.Instant/now))))) "instant toEpochMilli")
  (is (= "Long" (str (class (.getNano (java.time.Instant/now))))) "instant getNano"))

(deftest duration-past-i48
  ;; 1e14 ms > 2^47
  (is (= ["Long" true]
         (exact (.toMillis (java.time.Duration/ofSeconds 100000000000)) 100000000000000))))

(deftest parse-paths-at-i64-edge
  (is (= ["Long" true] (exact (Long/parseLong "9223372036854775807") Long/MAX_VALUE)) "parseLong")
  (is (= ["Long" true] (exact (Long/valueOf "9223372036854775807") Long/MAX_VALUE)) "valueOf")
  (is (= ["Long" true] (exact (Long/sum Long/MAX_VALUE 0) Long/MAX_VALUE)) "Long/sum"))

(deftest narrowing-to-long
  (is (= ["Long" true] (exact (.longValue (bigdec "9223372036854775807")) Long/MAX_VALUE))
      "BigDecimal longValue")
  (is (= ["Long" true] (exact (long 9.2e18) 9200000000000000000)) "long of a large double"))

(deftest file-and-runtime-readings
  (testing "File.length"
    (let [f (java.io.File/createTempFile "cljw-i48" ".txt")]
      (try
        (spit f "x")
        (is (= ["Long" true] (exact (.length f) 1)))
        (finally (.delete f)))))
  (is (= ["Long" true] (exact (.maxMemory (Runtime/getRuntime)) Long/MAX_VALUE))
      "Runtime maxMemory"))
