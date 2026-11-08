;; java.time value types (D-462 / ADR-0161 / D-510..D-512): Instant, Duration,
;; LocalDate, LocalTime, LocalDateTime, DayOfWeek / Month / ChronoUnit enums.
;; `(str v)` is the ISO toString (clj-grounded); pr-str's `#object[…]` wrapper is
;; the locked divergence AD-042, so every case reads values through `str` or the
;; instance methods.
;;
;; Migrated from the phase15 java_time e2e scripts (one cljw process each):
;; instant, duration, local_date_time, local_date, compare, sort,
;; local_date_arith, ldt_arith, arith3, duration_between, dow_month,
;; ldt_calendar. `testing` strings carry the old block names.
(ns suites.java-time-values-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest java-time-instant
  (testing "phase15_java_time_instant epoch0"
    (let [i (java.time.Instant/ofEpochSecond 0)]
      (is (= "1970-01-01T00:00:00Z" (str i)))
      (is (= [0 0 0] [(.getEpochSecond i) (.getNano i) (.toEpochMilli i)]))))
  (testing "sec-nanos"
    (let [i (java.time.Instant/ofEpochSecond 1704067200 500000000)]
      (is (= "2024-01-01T00:00:00.500Z" (str i)))
      (is (= 500000000 (.getNano i)))
      (is (= 1704067200500 (.toEpochMilli i)))))
  (testing "parse / ofEpochMilli"
    (is (= "2024-01-01T00:00:00Z" (str (java.time.Instant/parse "2024-01-01T00:00:00Z"))))
    (is (= "2024-01-01T00:00:00Z" (str (java.time.Instant/ofEpochMilli 1704067200000)))))
  (testing "value-eq"
    (is (= (java.time.Instant/ofEpochSecond 5) (java.time.Instant/ofEpochSecond 5)))
    (is (not= (java.time.Instant/ofEpochSecond 5) (java.time.Instant/ofEpochSecond 6))))
  (testing "instant-until (D-512)"
    (let [a (java.time.Instant/ofEpochSecond 0) b (java.time.Instant/ofEpochSecond 3661)]
      (is (= [3661 61 1 2]
             [(.until a b java.time.temporal.ChronoUnit/SECONDS)
              (.until a b java.time.temporal.ChronoUnit/MINUTES)
              (.until a b java.time.temporal.ChronoUnit/HOURS)
              (.until (java.time.Instant/ofEpochSecond 0) (java.time.Instant/ofEpochSecond 200000)
                      java.time.temporal.ChronoUnit/DAYS)])))
    (is (thrown-with-msg? Throwable #"time-based ChronoUnit"
          (.until (java.time.Instant/ofEpochSecond 0) (java.time.Instant/ofEpochSecond 1)
                  java.time.temporal.ChronoUnit/WEEKS))
        "instant-until-unsupported")))

(deftest java-time-duration
  (testing "phase15_java_time_duration str-forms"
    (is (= ["PT1M30S" "PT2H" "PT1H30M" "PT1.5S" "PT5.5S" "PT0S" "PT-30S" "PT1H1M1S"
            "PT-1H-1M-1S" "PT-1.5S" "PT-0.5S" "PT0.123456789S" "PT24H"]
           (mapv str [(java.time.Duration/ofSeconds 90)
                      (java.time.Duration/ofHours 2)
                      (java.time.Duration/ofMinutes 90)
                      (java.time.Duration/ofMillis 1500)
                      (java.time.Duration/ofSeconds 5 500000000)
                      (java.time.Duration/ofSeconds 0)
                      (java.time.Duration/ofSeconds -30)
                      (java.time.Duration/ofSeconds 3661)
                      (java.time.Duration/ofSeconds -3661)
                      (java.time.Duration/ofMillis -1500)
                      (java.time.Duration/ofSeconds -1 500000000)
                      (java.time.Duration/ofNanos 123456789)
                      (java.time.Duration/ofDays 1)]))))
  (testing "readers"
    (let [d (java.time.Duration/ofMillis -1500)]
      (is (= [-2 500000000 -1500] [(.getSeconds d) (.getNano d) (.toMillis d)])))
    (let [d (java.time.Duration/ofSeconds 90)]
      (is (= [90 0 90000 1] [(.getSeconds d) (.getNano d) (.toMillis d) (.toMinutes d)]))))
  (testing "value-eq"
    (is (= (java.time.Duration/ofSeconds 90) (java.time.Duration/ofMillis 90000)))
    (is (not= (java.time.Duration/ofSeconds 90) (java.time.Duration/ofSeconds 91)))))

(deftest java-time-local-date-time
  (testing "phase15_java_time_local_date_time str-forms"
    (is (= ["2024-01-01T12:30" "2024-01-01T12:30:45" "2024-01-01T12:30:45.500"
            "2024-06-15T00:00" "2024-12-31T00:00"]
           (mapv str [(java.time.LocalDateTime/of 2024 1 1 12 30)
                      (java.time.LocalDateTime/of 2024 1 1 12 30 45)
                      (java.time.LocalDateTime/of 2024 1 1 12 30 45 500000000)
                      (java.time.LocalDateTime/of 2024 6 15 0 0 0)
                      (java.time.LocalDateTime/of 2024 12 31 0 0)]))))
  (testing "readers"
    (let [d (java.time.LocalDateTime/of 2024 3 9 14 5 45 123456789)]
      (is (= [2024 3 9 14 5 45 123456789]
             [(.getYear d) (.getMonthValue d) (.getDayOfMonth d)
              (.getHour d) (.getMinute d) (.getSecond d) (.getNano d)]))))
  (testing "parse"
    (is (= "2024-01-01T12:30:45" (str (java.time.LocalDateTime/parse "2024-01-01T12:30:45"))))
    (is (= "2024-01-01T12:30" (str (java.time.LocalDateTime/parse "2024-01-01T12:30")))))
  (testing "value-eq"
    (is (= (java.time.LocalDateTime/of 2024 1 1 12 30 0) (java.time.LocalDateTime/of 2024 1 1 12 30)))
    (is (not= (java.time.LocalDateTime/of 2024 1 1 12 30) (java.time.LocalDateTime/of 2024 1 1 12 31)))))

(deftest java-time-local-date-and-time
  (testing "phase15_java_time_local_date localdate"
    (is (= ["2024-01-01" "2024-12-31" "0001-01-01"]
           (mapv str [(java.time.LocalDate/of 2024 1 1) (java.time.LocalDate/of 2024 12 31)
                      (java.time.LocalDate/of 1 1 1)])))
    (let [d (java.time.LocalDate/of 2024 3 9)]
      (is (= [2024 3 9] [(.getYear d) (.getMonthValue d) (.getDayOfMonth d)])))
    (is (= "2024-02-29" (str (java.time.LocalDate/parse "2024-02-29"))))
    (is (= "2024-02-10" (str (.plusDays (java.time.LocalDate/of 2024 1 1) 40))))
    (is (= (java.time.LocalDate/of 2024 1 1) (java.time.LocalDate/of 2024 1 1)))
    (is (not= (java.time.LocalDate/of 2024 1 1) (java.time.LocalDate/of 2024 1 2))))
  (testing "localtime"
    (is (= ["12:30" "12:30:45" "12:30:45.500" "00:00"]
           (mapv str [(java.time.LocalTime/of 12 30) (java.time.LocalTime/of 12 30 45)
                      (java.time.LocalTime/of 12 30 45 500000000) (java.time.LocalTime/of 0 0)])))
    (let [t (java.time.LocalTime/of 14 5 45 123456789)]
      (is (= [14 5 45 123456789] [(.getHour t) (.getMinute t) (.getSecond t) (.getNano t)])))
    (is (= "06:07:08" (str (java.time.LocalTime/parse "06:07:08"))))
    (is (= (java.time.LocalTime/of 12 30) (java.time.LocalTime/of 12 30 0)))
    (is (not= (java.time.LocalTime/of 12 30) (java.time.LocalTime/of 12 31))))
  (testing "to-local"
    (let [dt (java.time.LocalDateTime/of 2024 3 9 14 5 45 500000000)]
      (is (= "2024-03-09" (str (.toLocalDate dt))))
      (is (= "14:05:45.500" (str (.toLocalTime dt)))))))

(deftest java-time-compare-predicates
  (testing "phase15_java_time_compare instant"
    (let [a (java.time.Instant/ofEpochSecond 5) b (java.time.Instant/ofEpochSecond 9)]
      (is (= [true false false true] [(.isBefore a b) (.isAfter a b) (.isBefore a a) (.isAfter b a)]))))
  (testing "localdate"
    (let [a (java.time.LocalDate/of 2024 1 1) b (java.time.LocalDate/of 2024 6 1)]
      (is (= [true false false true]
             [(.isBefore a b) (.isAfter a b) (.isEqual a b) (.isEqual a (java.time.LocalDate/of 2024 1 1))]))))
  (testing "localtime-ldt"
    (let [a (java.time.LocalTime/of 6 0) b (java.time.LocalTime/of 18 0)]
      (is (= [true false] [(.isBefore a b) (.isAfter a b)])))
    (let [a (java.time.LocalDateTime/of 2024 1 1 6 0) b (java.time.LocalDateTime/of 2024 1 1 18 0)]
      (is (= [true false false] [(.isBefore a b) (.isAfter a b) (.isEqual a b)]))))
  (testing "duration-unary"
    (is (= [true false true false]
           [(.isZero (java.time.Duration/ofSeconds 0)) (.isZero (java.time.Duration/ofSeconds 5))
            (.isNegative (java.time.Duration/ofSeconds -1)) (.isNegative (java.time.Duration/ofSeconds 1))]))
    (is (= ["PT-1.5S" "PT30S" "PT30S" "PT0S"]
           [(str (.negated (java.time.Duration/ofMillis 1500)))
            (str (.abs (java.time.Duration/ofSeconds -30)))
            (str (.abs (java.time.Duration/ofSeconds 30)))
            (str (.negated (java.time.Duration/ofSeconds 0)))]))))

(deftest java-time-compare-and-sort
  ;; AD-043 pin: TEMPORAL compare is SIGN-based (clj answers a magnitude for
  ;; LocalDate/LocalDateTime); the string family is clj's compareTo magnitude.
  (testing "phase15_java_time_sort compare-sign"
    (is (= [-1 1 0]
           [(compare (java.time.Instant/ofEpochSecond 5) (java.time.Instant/ofEpochSecond 9))
            (compare (java.time.Instant/ofEpochSecond 9) (java.time.Instant/ofEpochSecond 5))
            (compare (java.time.Instant/ofEpochSecond 5) (java.time.Instant/ofEpochSecond 5))]))
    (is (= [1 -1 -1 -1]
           [(compare (java.time.LocalDate/of 2024 6 1) (java.time.LocalDate/of 2024 1 1))
            (compare (java.time.LocalTime/of 6 0) (java.time.LocalTime/of 18 0))
            (compare (java.time.Duration/ofSeconds 1) (java.time.Duration/ofSeconds 9))
            (compare (java.time.LocalDateTime/of 2024 1 1 6 0) (java.time.LocalDateTime/of 2024 1 1 18 0))])))
  (testing "sort"
    (is (= ["2024-01-01" "2024-03-01" "2024-06-01"]
           (mapv str (sort [(java.time.LocalDate/of 2024 6 1) (java.time.LocalDate/of 2024 1 1)
                            (java.time.LocalDate/of 2024 3 1)])))))
  (testing "string-family-magnitude"
    (is (= [-2 1 -2 -2 -2]
           [(compare "a" "c") (compare "abc" "ab") (compare :a :c) (compare 'aa 'ac) (compare \a \c)]))))

(deftest java-time-local-date-arith
  (testing "phase15_java_time_local_date_arith day-week"
    (is (= ["2024-02-10" "2023-12-31" "2024-01-15" "2024-01-01"]
           [(str (.plusDays (java.time.LocalDate/of 2024 1 1) 40))
            (str (.minusDays (java.time.LocalDate/of 2024 1 1) 1))
            (str (.plusWeeks (java.time.LocalDate/of 2024 1 1) 2))
            (str (.minusWeeks (java.time.LocalDate/of 2024 1 15) 2))])))
  (testing "month-year (civil clamp)"
    (is (= ["2024-02-29" "2023-02-28" "2025-01-15" "2024-02-29" "2025-02-28" "2019-06-15"]
           [(str (.plusMonths (java.time.LocalDate/of 2024 1 31) 1))
            (str (.plusMonths (java.time.LocalDate/of 2023 1 31) 1))
            (str (.plusMonths (java.time.LocalDate/of 2024 12 15) 1))
            (str (.minusMonths (java.time.LocalDate/of 2024 3 31) 1))
            (str (.plusYears (java.time.LocalDate/of 2024 2 29) 1))
            (str (.minusYears (java.time.LocalDate/of 2024 6 15) 5))])))
  (testing "leap-length"
    (is (= [true false false true]
           (mapv #(.isLeapYear (java.time.LocalDate/of % 1 1)) [2024 2023 1900 2000])))
    (is (= [29 28 30]
           [(.lengthOfMonth (java.time.LocalDate/of 2024 2 1))
            (.lengthOfMonth (java.time.LocalDate/of 2023 2 1))
            (.lengthOfMonth (java.time.LocalDate/of 2024 4 1))])))
  (testing "at-time"
    (let [d (java.time.LocalDate/of 2026 6 20)]
      (is (= ["2026-06-20T00:00" "2026-06-20T13:30" "2026-06-20T13:30:45"
              "2026-06-20T00:00:00.500" "2026-06-20"]
             [(str (.atStartOfDay d)) (str (.atTime d 13 30)) (str (.atTime d 13 30 45))
              (str (.atTime d 0 0 0 500000000)) (str (.toLocalDate (.atTime d 13 30)))])))))

(deftest java-time-ldt-arith
  (testing "phase15_java_time_ldt_arith day-week"
    (is (= ["2024-02-10T12:30" "2024-02-29T12:00" "2024-01-15T00:00"]
           [(str (.plusDays (java.time.LocalDateTime/of 2024 1 1 12 30) 40))
            (str (.minusDays (java.time.LocalDateTime/of 2024 3 1 12 0) 1))
            (str (.plusWeeks (java.time.LocalDateTime/of 2024 1 1 0 0) 2))])))
  (testing "time-carry (midnight carry/borrow)"
    (is (= ["2024-01-02T01:30" "2024-01-02T00:01" "2023-12-31T23:00"
            "2024-01-01T00:01:15" "2024-01-01T12:00:01.500"]
           [(str (.plusHours (java.time.LocalDateTime/of 2024 1 1 23 30) 2))
            (str (.plusMinutes (java.time.LocalDateTime/of 2024 1 1 23 59) 2))
            (str (.minusHours (java.time.LocalDateTime/of 2024 1 1 1 0) 2))
            (str (.plusSeconds (java.time.LocalDateTime/of 2024 1 1 0 0 30) 45))
            (str (.plusNanos (java.time.LocalDateTime/of 2024 1 1 12 0 0 0) 1500000000))])))
  (testing "phase15_java_time_ldt_calendar months"
    (is (= ["2024-02-29T14:30" "2023-02-28T09:00" "2025-02-15T06:00" "2024-02-29T00:00"]
           [(str (.plusMonths (java.time.LocalDateTime/of 2024 1 31 14 30) 1))
            (str (.plusMonths (java.time.LocalDateTime/of 2023 1 31 9 0) 1))
            (str (.plusMonths (java.time.LocalDateTime/of 2024 12 15 6 0) 2))
            (str (.minusMonths (java.time.LocalDateTime/of 2024 3 31 0 0) 1))])))
  (testing "years"
    (is (= ["2025-02-28T23:59:59" "2019-06-15T12:00"]
           [(str (.plusYears (java.time.LocalDateTime/of 2024 2 29 23 59 59) 1))
            (str (.minusYears (java.time.LocalDateTime/of 2024 6 15 12 0) 5))]))))

(deftest java-time-arith3
  (testing "phase15_java_time_arith3 instant"
    (let [i (java.time.Instant/ofEpochSecond 100 0)]
      (is (= [105 101500 1 50]
             [(.getEpochSecond (.plusSeconds i 5)) (.toEpochMilli (.plusMillis i 1500))
              (.getNano (.plusNanos i 1)) (.getEpochSecond (.minusSeconds i 50))]))))
  (testing "duration"
    (is (= ["PT15S" "PT2M" "PT5.5S" "PT12S" "PT2.5S" "PT7S"]
           [(str (.plusSeconds (java.time.Duration/ofSeconds 5) 10))
            (str (.plusMinutes (java.time.Duration/ofSeconds 0) 2))
            (str (.plus (java.time.Duration/ofSeconds 5) (java.time.Duration/ofMillis 500)))
            (str (.multipliedBy (java.time.Duration/ofSeconds 3) 4))
            (str (.dividedBy (java.time.Duration/ofSeconds 10) 4))
            (str (.minusSeconds (java.time.Duration/ofSeconds 10) 3))])))
  (testing "localtime (wraps mod 24h)"
    (is (= ["01:00" "23:00" "13:15" "12:00:01.500"]
           [(str (.plusHours (java.time.LocalTime/of 23 0) 2))
            (str (.minusHours (java.time.LocalTime/of 1 0) 2))
            (str (.plusMinutes (java.time.LocalTime/of 12 30) 45))
            (str (.plusNanos (java.time.LocalTime/of 12 0 0 0) 1500000000))]))))

(deftest java-time-duration-between
  (testing "phase15_java_time_duration_between between"
    (is (= ["PT1M30S" "PT-1M-30S" "PT1H30M" "PT2H30M"]
           [(str (java.time.Duration/between (java.time.Instant/ofEpochSecond 100) (java.time.Instant/ofEpochSecond 190)))
            (str (java.time.Duration/between (java.time.Instant/ofEpochSecond 190) (java.time.Instant/ofEpochSecond 100)))
            (str (java.time.Duration/between (java.time.LocalDateTime/of 2024 1 1 12 0) (java.time.LocalDateTime/of 2024 1 1 13 30)))
            (str (java.time.Duration/between (java.time.LocalTime/of 6 0) (java.time.LocalTime/of 8 30)))])))
  (testing "instant-plus-dur"
    (is (= ["1970-01-01T00:01:45.500Z" "1970-01-01T00:00:50Z"]
           [(str (.plus (java.time.Instant/ofEpochSecond 100) (java.time.Duration/ofSeconds 5 500000000)))
            (str (.minus (java.time.Instant/ofEpochSecond 100) (java.time.Duration/ofSeconds 50)))])))
  (testing "ldt-plus-dur"
    (is (= ["2024-01-02T01:00" "2024-01-01T23:00"]
           [(str (.plus (java.time.LocalDateTime/of 2024 1 1 23 0) (java.time.Duration/ofHours 2)))
            (str (.minus (java.time.LocalDateTime/of 2024 1 2 1 0) (java.time.Duration/ofHours 2)))]))))

(deftest java-time-dow-month-enums
  (testing "phase15_java_time_dow_month localdate"
    (let [d (java.time.LocalDate/of 2024 3 9)]
      (is (= ["SATURDAY" 6 "MARCH" 3 69]
             [(str (.getDayOfWeek d)) (.getValue (.getDayOfWeek d))
              (str (.getMonth d)) (.getValue (.getMonth d)) (.getDayOfYear d)]))))
  (testing "localdatetime"
    (let [dt (java.time.LocalDateTime/of 2024 12 25 10 0)]
      (is (= ["WEDNESDAY" "DECEMBER"] [(str (.getDayOfWeek dt)) (str (.getMonth dt))]))))
  (testing "enum-eq"
    (is (= (.getDayOfWeek (java.time.LocalDate/of 2024 3 9)) (.getDayOfWeek (java.time.LocalDate/of 2024 3 16))))
    (is (not= (.getMonth (java.time.LocalDate/of 2024 3 9)) (.getMonth (java.time.LocalDate/of 2024 4 9)))))
  (testing "dow-boundary"
    (is (= ["THURSDAY" "SUNDAY"]
           [(str (.getDayOfWeek (java.time.LocalDate/of 1970 1 1)))
            (str (.getDayOfWeek (java.time.LocalDate/of 2024 3 10)))])))
  (testing "chrono-unit"
    (is (= ["Days" "DAYS" "HalfDays" "MILLENNIA" true false]
           [(str java.time.temporal.ChronoUnit/DAYS)
            (.name java.time.temporal.ChronoUnit/DAYS)
            (str java.time.temporal.ChronoUnit/HALF_DAYS)
            (.name java.time.temporal.ChronoUnit/MILLENNIA)
            (= java.time.temporal.ChronoUnit/DAYS java.time.temporal.ChronoUnit/DAYS)
            (= java.time.temporal.ChronoUnit/DAYS java.time.temporal.ChronoUnit/WEEKS)])))
  (testing "until"
    (let [a (java.time.LocalDate/of 2020 1 1) b (java.time.LocalDate/of 2021 3 15)]
      (is (= [439 62 14 1 1 -60]
             [(.until a b java.time.temporal.ChronoUnit/DAYS)
              (.until a b java.time.temporal.ChronoUnit/WEEKS)
              (.until a b java.time.temporal.ChronoUnit/MONTHS)
              (.until a b java.time.temporal.ChronoUnit/YEARS)
              (.until (java.time.LocalDate/of 2020 1 31) (java.time.LocalDate/of 2020 3 1)
                      java.time.temporal.ChronoUnit/MONTHS)
              (.until (java.time.LocalDate/of 2020 3 1) (java.time.LocalDate/of 2020 1 1)
                      java.time.temporal.ChronoUnit/DAYS)])))
    (is (thrown-with-msg? Throwable #"date-based ChronoUnit"
          (.until (java.time.LocalDate/of 2020 1 1) (java.time.LocalDate/of 2020 1 2)
                  java.time.temporal.ChronoUnit/HOURS))
        "until-unsupported"))
  (testing "ldt-until"
    (let [a (java.time.LocalDateTime/of 2020 1 1 0 0 0) b (java.time.LocalDateTime/of 2021 3 2 6 30 15)]
      (is (= [426 10230 613830 36829815 14 1]
             (mapv #(.until a b %)
                   [java.time.temporal.ChronoUnit/DAYS java.time.temporal.ChronoUnit/HOURS
                    java.time.temporal.ChronoUnit/MINUTES java.time.temporal.ChronoUnit/SECONDS
                    java.time.temporal.ChronoUnit/MONTHS java.time.temporal.ChronoUnit/YEARS])))))
  (testing "enum-const"
    (is (= ["MONDAY" 7 "MONDAY" "JANUARY" 12 "MARCH"]
           [(str java.time.DayOfWeek/MONDAY) (.getValue java.time.DayOfWeek/SUNDAY)
            (.name java.time.DayOfWeek/MONDAY) (str java.time.Month/JANUARY)
            (.getValue java.time.Month/DECEMBER) (.name java.time.Month/MARCH)])))
  (testing "enum-identity"
    (let [d (java.time.LocalDate/of 2024 3 9)]
      (is (= (.getDayOfWeek d) java.time.DayOfWeek/SATURDAY))
      (is (identical? (.getDayOfWeek d) java.time.DayOfWeek/SATURDAY))
      (is (= (.getMonth d) java.time.Month/MARCH))
      (is (identical? (.getMonth d) java.time.Month/MARCH))))
  (testing "enum-compare (AD-043 sign pin)"
    (is (= [-1 1 -1 ["MONDAY" "WEDNESDAY" "FRIDAY"]]
           [(compare java.time.DayOfWeek/MONDAY java.time.DayOfWeek/SUNDAY)
            (compare java.time.Month/MARCH java.time.Month/JANUARY)
            (compare java.math.RoundingMode/UP java.math.RoundingMode/DOWN)
            (mapv str (sort [java.time.DayOfWeek/WEDNESDAY java.time.DayOfWeek/MONDAY
                             java.time.DayOfWeek/FRIDAY]))]))))
