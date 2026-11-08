;; Date / java.time values: `=` by value implies equal `hash` (AD-009, JVM
;; hashCode formulas), so they work as hash-set elements, map keys and in
;; distinct / frequencies / group-by. Kanban 20260927170834-6aa890c7.
(ns suites.temporal-hash-eq-test
  (:require [clojure.test :refer [deftest is]]))

(defn- pairs []
  [[(java.util.Date. 5) (java.util.Date. 5) 5]
   [(java.time.Instant/ofEpochSecond 5) (java.time.Instant/ofEpochSecond 5) 5]
   [(java.time.Duration/ofSeconds 5) (java.time.Duration/ofSeconds 5) 5]
   [(java.time.LocalDate/of 2020 3 1) (java.time.LocalDate/of 2020 3 1) 4137153]
   [(java.time.LocalDateTime/of 2020 3 1 10 0) (java.time.LocalDateTime/of 2020 3 1 10 0) -418824068]
   [(java.time.LocalTime/of 10 0) (java.time.LocalTime/of 10 0) -415866691]])

(deftest equal-values-hash-equal
  (doseq [[a b h] (pairs)]
    (is (= a b) (pr-str a))
    (is (= h (hash a) (hash b)) (pr-str a))
    (is (= 1 (count (hash-set a b))) (pr-str a))
    (is (= :v (get {a :v} b)) (pr-str a))
    (is (= [a] (distinct [a b])) (pr-str a))
    (is (= {a 2} (frequencies [a b])) (pr-str a))
    (is (= 1 (count (group-by identity [a b]))) (pr-str a))))

(deftest jvm-hash-edges
  (is (= [0 361 361 4033311 1435055922 -1857113749]
         (mapv hash [(java.util.Date. -1)
                     (java.time.Instant/ofEpochSecond -5 7)
                     (java.time.Duration/ofSeconds -5 7)
                     (java.time.LocalDate/of 1969 12 31)
                     (java.time.LocalDateTime/of 1960 1 1 23 59 59 999)
                     (java.time.LocalTime/of 23 59 59 999999999)]))))

(deftest distinct-values-stay-distinct
  (is (= 2 (count (hash-set (java.util.Date. 5) (java.util.Date. 6)))))
  (is (= 2 (count (hash-set (java.time.LocalDate/of 2020 3 1) (java.time.LocalDate/of 2020 3 2)))))
  (is (= 1 (count (set [(java.time.Duration/ofSeconds 5) (java.time.Duration/ofMillis 5000)]))))
  (is (= 1 (count (hash-set #inst "2020-03-01T00:00:00.000-00:00"
                            #inst "2020-03-01T00:00:00.000-00:00")))))

;; JVM oracle (clj 1.12): `compare` 0 goes with `=` and an equal hash, so a
;; sorted collection and a hashed one agree on which temporal values are one.
(deftest compare-agrees-with-eq-and-hash
  (doseq [[a b _] (pairs)]
    (is (zero? (compare a b)) (pr-str a))
    (is (= 1 (count (sorted-set a b))) (pr-str a)))
  (require 'clojure.instant)
  (let [r (resolve 'clojure.instant/read-instant-timestamp)
        t (r "1970-01-01T00:00:00.005Z")
        u (r "1970-01-01T00:00:00.005Z")
        v (r "1970-01-01T00:00:00.005000001Z")]
    (is (= [0 -1 1] [(compare t u) (compare t v) (compare v t)]))
    (is (= [true false] [(= t u) (= t v)]))
    (is (= 5 (hash t) (hash u) (hash v)))
    (is (= 2 (count (sorted-set t u v)) (count (hash-set t u v))))))
