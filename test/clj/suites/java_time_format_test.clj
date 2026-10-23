;; java.time.format: DateTimeFormatter, DateTimeFormatterBuilder and the
;; Parsed TemporalAccessor; java.time.temporal.ChronoField; the fixed-offset
;; java.time.ZoneId / ZoneOffset; the `from` conversions.
;;
;; Every expected string is what JVM Clojure 1.12 on JDK 25 printed for the
;; same form: the `str` of the value, or `<SimpleName>: <message>` of the
;; exception. A ClassCastException message names JVM classes cljw does not
;; have, so those rows compare the class only (`outcome-class`).
;;
;; The malli 0.20.2 `malli.transform` string<->date formatters are the
;; driving consumer, so they come first, built exactly as malli builds them.
(ns suites.java-time-format-test
  (:require [clojure.test :refer [deftest is testing]])
  (:import (java.time Instant LocalDate LocalDateTime LocalTime ZoneId ZoneOffset)
           (java.time.format DateTimeFormatter DateTimeFormatterBuilder)
           (java.time.temporal ChronoField)
           (java.util Date)))

(defmacro outcome
  "The str of `form`'s value, or `<SimpleName>: <message>` of what it threw."
  [form]
  `(try (str ~form)
        (catch Exception ex# (str (.getSimpleName (class ex#)) ": " (ex-message ex#)))))

(defmacro outcome-class
  "The str of `form`'s value, or the simple class name of what it threw."
  [form]
  `(try (str ~form)
        (catch Exception ex# (.getSimpleName (class ex#)))))

(def malli-in
  (-> (DateTimeFormatterBuilder.)
      (.appendPattern "yyyy-MM-dd['T'HH:mm:ss]")
      (.optionalStart)
      (.appendFraction ChronoField/MICRO_OF_SECOND, 0, 9, true)
      (.optionalEnd)
      (.optionalStart)
      (.appendOffset "+HHMMss", "Z")
      (.optionalEnd)
      (.optionalStart)
      (.appendOffset "+HH:MM:ss", "Z")
      (.optionalEnd)
      (.parseDefaulting ChronoField/HOUR_OF_DAY 0)
      (.parseDefaulting ChronoField/OFFSET_SECONDS 0)
      (.toFormatter)))

(def malli-out
  (-> (DateTimeFormatter/ofPattern "yyyy-MM-dd'T'HH:mm:ss.SSSXXX")
      (.withZone (ZoneId/of "UTC"))))

(deftest malli-string->date
  (is (= ["2024-01-02T00:00:00Z"
          "2024-01-02T03:04:05Z"
          "2024-01-02T03:04:05.123456Z"
          "2024-01-02T03:04:05Z"
          "2024-01-02T01:34:05Z"
          "2024-01-02T01:34:05.500Z"
          "2024-01-02T08:04:05Z"]
         (mapv #(outcome (Instant/from (.parse malli-in %)))
               ["2024-01-02" "2024-01-02T03:04:05" "2024-01-02T03:04:05.123456789"
                "2024-01-02T03:04:05Z" "2024-01-02T03:04:05+0130" "2024-01-02T03:04:05.5+01:30"
                "2024-01-02T03:04:05-05:00"])))
  (is (= "DateTimeParseException: Text '2024-01-02T' could not be parsed, unparsed text found at index 10"
         (outcome (Instant/from (.parse malli-in "2024-01-02T")))))
  (is (= "DateTimeParseException: Text 'nope' could not be parsed at index 0"
         (outcome (Instant/from (.parse malli-in "nope")))))
  (is (= 1704164645500 (inst-ms (Date/from (Instant/from (.parse malli-in "2024-01-02T03:04:05.5Z")))))))

(deftest malli-date->string
  (is (= "2024-01-02T03:04:05.123Z" (outcome (.format malli-out (Instant/ofEpochMilli 1704164645123)))))
  (is (= "1970-01-01T00:00:00.000Z" (outcome (.format malli-out (Instant/ofEpochMilli 0)))))
  (testing "a Date is not a TemporalAccessor"
    (is (= "ClassCastException" (outcome-class (.format malli-out (Date/from (Instant/ofEpochSecond 1))))))))

(deftest of-pattern-format
  (is (= "09/03/2024" (outcome (.format (DateTimeFormatter/ofPattern "dd/MM/yyyy") (LocalDate/of 2024 3 9)))))
  (is (= "Mar 9, 2024" (outcome (.format (DateTimeFormatter/ofPattern "MMM d, yyyy") (LocalDate/of 2024 3 9)))))
  (is (= "Saturday, March 09" (outcome (.format (DateTimeFormatter/ofPattern "EEEE, MMMM dd") (LocalDate/of 2024 3 9)))))
  (is (= "Sat 24 69" (outcome (.format (DateTimeFormatter/ofPattern "EEE yy D") (LocalDate/of 2024 3 9)))))
  (is (= "2024-03-09 07:05" (outcome (.format (DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm") (LocalDateTime/of 2024 3 9 7 5)))))
  (is (= "7:05 PM" (outcome (.format (DateTimeFormatter/ofPattern "h:mm a") (LocalTime/of 19 5)))))
  (is (= "01:02:03.004 4500000" (outcome (.format (DateTimeFormatter/ofPattern "HH:mm:ss.SSS n") (LocalTime/of 1 2 3 4500000)))))
  (testing "a field the temporal does not carry"
    (is (= "UnsupportedTemporalTypeException: Unsupported field: YearOfEra"
           (outcome (.format (DateTimeFormatter/ofPattern "yyyy-MM-dd") (LocalTime/of 1 2)))))
    (is (= "UnsupportedTemporalTypeException: Unsupported field: YearOfEra"
           (outcome (.format (DateTimeFormatter/ofPattern "yyyy") (Instant/ofEpochSecond 0))))))
  (testing "an optional section drops when its fields are absent"
    (is (= "2024-01-02" (outcome (.format (DateTimeFormatter/ofPattern "yyyy-MM-dd['T'HH:mm]") (LocalDate/of 2024 1 2)))))
    (is (= "2024-01-02T03:04" (outcome (.format (DateTimeFormatter/ofPattern "yyyy-MM-dd['T'HH:mm]") (LocalDateTime/of 2024 1 2 3 4))))))
  (testing "withZone re-projects an Instant"
    (is (= "ClassCastException"
           (outcome-class (.format (DateTimeFormatter/ofPattern "yyyyMMdd'T'HHmmssX")
                                   (.withZone (DateTimeFormatter/ofPattern "yyyy") (ZoneOffset/ofHours 2))))))
    (is (= "19700101T020000+0200"
           (outcome (.format (.withZone (DateTimeFormatter/ofPattern "yyyyMMdd'T'HHmmssXX") (ZoneOffset/ofHours 2)) (Instant/ofEpochSecond 0)))))
    (is (= "1969-12-31T18:30-05:30 -05:30"
           (outcome (.format (.withZone (DateTimeFormatter/ofPattern "yyyy-MM-dd'T'HH:mmxxx VV") (ZoneOffset/of "-05:30")) (Instant/ofEpochSecond 0))))))
  (testing "toString and pattern errors"
    (is (= "Value(YearOfEra,4,19,EXCEEDS_PAD)'-'Value(MonthOfYear,2)'-'Value(DayOfMonth,2)'T'Value(HourOfDay,2)':'Value(MinuteOfHour,2)':'Value(SecondOfMinute,2)'.'Fraction(NanoOfSecond,3,3)Offset(+HH:MM,'Z')"
           (outcome (DateTimeFormatter/ofPattern "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"))))
    (is (= "IllegalArgumentException: Unknown pattern letter: b" (outcome (DateTimeFormatter/ofPattern "bogus{"))))))

(deftest iso-constants-format
  (is (= "2024-03-09" (outcome (.format DateTimeFormatter/ISO_LOCAL_DATE (LocalDate/of 2024 3 9)))))
  (is (= "10:15:30.5" (outcome (.format DateTimeFormatter/ISO_LOCAL_TIME (LocalTime/of 10 15 30 500000000)))))
  (is (= "10:15:00" (outcome (.format DateTimeFormatter/ISO_LOCAL_TIME (LocalTime/of 10 15)))))
  (is (= "2024-03-09T10:15:00" (outcome (.format DateTimeFormatter/ISO_LOCAL_DATE_TIME (LocalDateTime/of 2024 3 9 10 15)))))
  (is (= "2024-01-01T00:00:00.500Z" (outcome (.format DateTimeFormatter/ISO_INSTANT (Instant/ofEpochSecond 1704067200 500000000)))))
  (is (= "20240309" (outcome (.format DateTimeFormatter/BASIC_ISO_DATE (LocalDate/of 2024 3 9)))))
  (is (= "2024-03-09" (outcome (.format DateTimeFormatter/ISO_DATE (LocalDate/of 2024 3 9)))))
  (is (= "UnsupportedTemporalTypeException: Unsupported field: OffsetSeconds"
         (outcome (.format DateTimeFormatter/ISO_OFFSET_DATE_TIME (LocalDateTime/of 2024 3 9 10 15)))))
  (is (= "1969-12-31T21:00:00-03:00"
         (outcome (.format (.withZone DateTimeFormatter/ISO_OFFSET_DATE_TIME (ZoneOffset/ofHours -3)) (Instant/ofEpochSecond 0)))))
  (is (= "Value(Year,4,10,EXCEEDS_PAD)'-'Value(MonthOfYear,2)'-'Value(DayOfMonth,2)" (outcome DateTimeFormatter/ISO_LOCAL_DATE)))
  (is (= "ParseCaseSensitive(false)Instant()" (outcome DateTimeFormatter/ISO_INSTANT))))

(deftest parse-and-convert
  (is (= "2024-01-01T00:00:00.250Z" (outcome (Instant/from (.parse DateTimeFormatter/ISO_INSTANT "2024-01-01T00:00:00.25Z")))))
  (is (= "2024-01-01T08:00:00Z" (outcome (Instant/from (.parse DateTimeFormatter/ISO_OFFSET_DATE_TIME "2024-01-01T10:00:00+02:00")))))
  (is (= "2024-03-09" (outcome (LocalDate/parse "20240309" DateTimeFormatter/BASIC_ISO_DATE))))
  (is (= "2024-03-09" (outcome (LocalDate/parse "09/03/2024" (DateTimeFormatter/ofPattern "dd/MM/yyyy")))))
  (is (= "2024-03-09T07:05" (outcome (LocalDateTime/parse "2024-03-09 07:05" (DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm")))))
  (is (= "19:05" (outcome (LocalTime/parse "7:05 PM" (DateTimeFormatter/ofPattern "h:mm a")))))
  (is (= "2024-03-09" (outcome (LocalDate/parse "Mar 9, 2024" (DateTimeFormatter/ofPattern "MMM d, yyyy")))))
  (is (= "2024-03-09" (outcome (LocalDate/from (.parse DateTimeFormatter/ISO_LOCAL_DATE_TIME "2024-03-09T01:02")))))
  (is (= "01:02" (outcome (LocalTime/from (.parse DateTimeFormatter/ISO_LOCAL_DATE_TIME "2024-03-09T01:02")))))
  (is (= "2024-03-09T01:02:03.400" (outcome (LocalDateTime/from (.parse DateTimeFormatter/ISO_LOCAL_DATE_TIME "2024-03-09T01:02:03.4")))))
  (testing "failures"
    (is (= "DateTimeParseException: Text '2024-02-30' could not be parsed: Invalid date 'FEBRUARY 30'"
           (outcome (LocalDate/parse "2024-02-30" DateTimeFormatter/ISO_LOCAL_DATE))))
    (is (= "DateTimeParseException: Text '2024-03-09x' could not be parsed, unparsed text found at index 10"
           (outcome (LocalDate/parse "2024-03-09x" DateTimeFormatter/ISO_LOCAL_DATE))))
    (is (= "DateTimeException: Unable to obtain LocalDate from TemporalAccessor: {},ISO resolved to 10:15 of type java.time.format.Parsed"
           (outcome (LocalDate/from (.parse (DateTimeFormatter/ofPattern "HH:mm") "10:15"))))))
  (testing "the Parsed accessor"
    (is (= 2024 (.getLong (.parse DateTimeFormatter/ISO_LOCAL_DATE "2024-03-09") ChronoField/YEAR)))
    (is (false? (.isSupported (.parse DateTimeFormatter/ISO_LOCAL_DATE "2024-03-09") ChronoField/HOUR_OF_DAY))))
  (testing "the exception classes catch by their JVM names"
    (is (= :caught (try (LocalDate/parse "x" DateTimeFormatter/ISO_LOCAL_DATE)
                        (catch java.time.format.DateTimeParseException _ :caught))))
    (is (= :caught (try (.format DateTimeFormatter/ISO_LOCAL_DATE (LocalTime/of 1 2))
                        (catch java.time.DateTimeException _ :caught))))))

(deftest adjacent-value-parsing
  (testing "a fixed-width fraction reserves its digits in the variable-width year"
    (is (= "2024-01-01T12:00:00.123"
           (outcome (LocalDateTime/parse "20240101120000123" (DateTimeFormatter/ofPattern "yyyyMMddHHmmssSSS"))))))
  (is (= "Value(YearOfEra,4,19,EXCEEDS_PAD)Value(MonthOfYear,2)Value(DayOfMonth,2)Value(HourOfDay,2)Value(MinuteOfHour,2)Value(SecondOfMinute,2)Fraction(NanoOfSecond,3,3)"
         (outcome (DateTimeFormatter/ofPattern "yyyyMMddHHmmssSSS")))))

(deftest formatter-identity-and-locale
  (is (identical? DateTimeFormatter/ISO_DATE DateTimeFormatter/ISO_DATE))
  (is (= "Mar 9" (outcome (.format (.withLocale (DateTimeFormatter/ofPattern "MMM d") java.util.Locale/US)
                                   (LocalDate/of 2024 3 9))))))

(deftest instant-parse-is-iso-instant
  (is (= "DateTimeParseException: Text 'x' could not be parsed at index 0" (outcome (Instant/parse "x")))))

(deftest a-method-fn-checks-its-receiver
  (testing "Class/.member hands out the raw method; a foreign receiver raises instead of being read as a formatter"
    (is (thrown? Exception (DateTimeFormatter/.parse "x" "y")))
    (is (thrown? Exception (DateTimeFormatterBuilder/.appendLiteral "s" "t")))))

(deftest builder
  (is (= "2024/3 at 07"
         (outcome (.format (-> (DateTimeFormatterBuilder.) (.appendValue ChronoField/YEAR 4) (.appendLiteral \/)
                               (.appendValue ChronoField/MONTH_OF_YEAR) (.appendLiteral " at ")
                               (.appendValue ChronoField/HOUR_OF_DAY 2) (.toFormatter))
                           (LocalDateTime/of 2024 3 9 7 5)))))
  (is (= "March" (outcome (.format (-> (DateTimeFormatterBuilder.) (.appendText ChronoField/MONTH_OF_YEAR) (.toFormatter))
                                   (LocalDate/of 2024 3 9)))))
  (is (= "2024-03-09" (outcome (LocalDate/parse "MARCH 2024 9"
                                                (-> (DateTimeFormatterBuilder.) (.parseCaseInsensitive)
                                                    (.appendPattern "MMMM yyyy d") (.toFormatter))))))
  (is (= "2024-03-09!" (outcome (.format (-> (DateTimeFormatterBuilder.) (.append DateTimeFormatter/ISO_LOCAL_DATE)
                                             (.appendLiteral "!") (.toFormatter))
                                         (LocalDate/of 2024 3 9))))))

(deftest chrono-field
  (is (= "HourOfDay" (outcome ChronoField/HOUR_OF_DAY)))
  (is (= "MICRO_OF_SECOND" (.name ChronoField/MICRO_OF_SECOND)))
  (is (= 30 (count (ChronoField/values))))
  (is (= ChronoField/YEAR (ChronoField/valueOf "YEAR"))))

(deftest zones
  (is (= ["UTC" "Z" "+02:00" "UTC+01:00"]
         (mapv #(outcome (ZoneId/of %)) ["UTC" "Z" "+02:00" "UTC+01:00"])))
  (is (= "+02:00" (outcome (ZoneOffset/ofHours 2))))
  (is (= "Z" (outcome ZoneOffset/UTC)))
  (is (= -19800 (.getTotalSeconds (ZoneOffset/of "-05:30"))))
  (is (= "+05:45" (outcome (ZoneOffset/ofHoursMinutes 5 45))))
  (is (= "GMT" (.getId (ZoneId/of "GMT"))))
  (testing "= and hash by value, with the JDK hashCode"
    (is (= (ZoneOffset/ofHours 2) (ZoneOffset/of "+02:00")))
    (is (not= (ZoneOffset/of "Z") (ZoneId/of "UTC")))
    (is (= 7200 (hash (ZoneOffset/ofHours 2))))
    (is (= 84356 (hash (ZoneId/of "UTC")))))
  (is (= "DateTimeException: Zone offset hours not in valid range: value 25 is not in the range -18 to 18"
         (outcome (ZoneOffset/of "+25:00"))))
  (testing "a region zone needs the tz database cljw does not ship: it raises, never guesses"
    (is (re-find #"Unknown time-zone ID: Europe/Paris" (outcome (ZoneId/of "Europe/Paris"))))))

(deftest from-conversions
  (is (= 5000 (inst-ms (Date/from (Instant/ofEpochSecond 5)))))
  (is (= "1970-01-01T00:00:07Z" (outcome (Instant/from (Instant/ofEpochSecond 7))))))
