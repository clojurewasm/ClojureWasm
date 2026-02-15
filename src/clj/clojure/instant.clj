;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/src/clj/clojure/instant.clj
;; Upstream lines: 295
;; CLJW markers: 5

(ns clojure.instant)

;; CLJW: *warn-on-reflection* not supported, skipped

;;; ------------------------------------------------------------------------
;;; convenience macros

(defmacro ^:private fail
  [msg]
  ;; CLJW: RuntimeException. → ex-info
  `(throw (ex-info ~msg {})))

(defmacro ^:private verify
  ([test msg] `(when-not ~test (fail ~msg)))
  ([test] `(verify ~test ~(str "failed: " (pr-str test)))))

(defn- divisible?
  [num div]
  (zero? (mod num div)))

(defn- indivisible?
  [num div]
  (not (divisible? num div)))

;;; ------------------------------------------------------------------------
;;; parser implementation

(defn- parse-int [s]
  (Long/parseLong s))

;; CLJW: zero-fill-right without StringBuilder — pure Clojure
(defn- zero-fill-right [s width]
  (let [n (count s)]
    (cond (= width n) s
          (< width n) (subs s 0 width)
          :else (apply str s (repeat (- width n) "0")))))

(def ^:private timestamp
  #"(\d\d\d\d)(?:-(\d\d)(?:-(\d\d)(?:[T](\d\d)(?::(\d\d)(?::(\d\d)(?:[.](\d+))?)?)?)?)?)?(?:[Z]|([-+])(\d\d):(\d\d))?")

(defn parse-timestamp
  "Parse a string containing an RFC3339-like like timestamp.

The function new-instant is called with the following arguments.

                min  max           default
                ---  ------------  -------
  years          0           9999      N/A (s must provide years)
  months         1             12        1
  days           1             31        1 (actual max days depends
  hours          0             23        0  on month and year)
  minutes        0             59        0
  seconds        0             60        0 (though 60 is only valid
  nanoseconds    0      999999999        0  when minutes is 59)
  offset-sign   -1              1        0
  offset-hours   0             23        0
  offset-minutes 0             59        0

These are all integers and will be non-nil. (The listed defaults
will be passed if the corresponding field is not present in s.)

Grammar (of s):

  date-fullyear   = 4DIGIT
  date-month      = 2DIGIT  ; 01-12
  date-mday       = 2DIGIT  ; 01-28, 01-29, 01-30, 01-31 based on
                            ; month/year
  time-hour       = 2DIGIT  ; 00-23
  time-minute     = 2DIGIT  ; 00-59
  time-second     = 2DIGIT  ; 00-58, 00-59, 00-60 based on leap second
                            ; rules
  time-secfrac    = '.' 1*DIGIT
  time-numoffset  = ('+' / '-') time-hour ':' time-minute
  time-offset     = 'Z' / time-numoffset

  time-part       = time-hour [ ':' time-minute [ ':' time-second
                    [time-secfrac] [time-offset] ] ]

  timestamp       = date-year [ '-' date-month [ '-' date-mday
                    [ 'T' time-part ] ] ]

Unlike RFC3339:

  - we only parse the timestamp format
  - timestamp can elide trailing components
  - time-offset is optional (defaults to +00:00)

Though time-offset is syntactically optional, a missing time-offset
will be treated as if the time-offset zero (+00:00) had been
specified.
"
  [new-instant cs]
  (if-let [[_ years months days hours minutes seconds fraction
            offset-sign offset-hours offset-minutes]
           (re-matches timestamp cs)]
    (new-instant
     (parse-int years)
     (if-not months   1 (parse-int months))
     (if-not days     1 (parse-int days))
     (if-not hours    0 (parse-int hours))
     (if-not minutes  0 (parse-int minutes))
     (if-not seconds  0 (parse-int seconds))
     (if-not fraction 0 (parse-int (zero-fill-right fraction 9)))
     (cond (= "-" offset-sign) -1
           (= "+" offset-sign)  1
           :else                0)
     (if-not offset-hours   0 (parse-int offset-hours))
     (if-not offset-minutes 0 (parse-int offset-minutes)))
    (fail (str "Unrecognized date/time syntax: " cs))))

;;; ------------------------------------------------------------------------
;;; Verification of Extra-Grammatical Restrictions from RFC3339

(defn- leap-year?
  [year]
  (and (divisible? year 4)
       (or (indivisible? year 100)
           (divisible? year 400))))

(def ^:private days-in-month
  (let [dim-norm [nil 31 28 31 30 31 30 31 31 30 31 30 31]
        dim-leap [nil 31 29 31 30 31 30 31 31 30 31 30 31]]
    (fn [month leap-year?]
      ((if leap-year? dim-leap dim-norm) month))))

(defn validated
  "Return a function which constructs an instant by calling constructor
after first validating that those arguments are in range and otherwise
plausible. The resulting function will throw an exception if called
with invalid arguments."
  [new-instance]
  (fn [years months days hours minutes seconds nanoseconds
       offset-sign offset-hours offset-minutes]
    (verify (<= 1 months 12))
    (verify (<= 1 days (days-in-month months (leap-year? years))))
    (verify (<= 0 hours 23))
    (verify (<= 0 minutes 59))
    (verify (<= 0 seconds (if (= minutes 59) 60 59)))
    (verify (<= 0 nanoseconds 999999999))
    (verify (<= -1 offset-sign 1))
    (verify (<= 0 offset-hours 23))
    (verify (<= 0 offset-minutes 59))
    (new-instance years months days hours minutes seconds nanoseconds
                  offset-sign offset-hours offset-minutes)))

;;; ------------------------------------------------------------------------
;;; CLJW: instant representation — Date class instance wrapping RFC3339 string.
;;; CW stores instants as reified java.util.Date maps with :inst key.
;;; The parse-timestamp + validated pipeline ensures the string is valid.

(defn- construct-date
  "Construct a Date instance from parsed timestamp components.
  Returns a reified java.util.Date with the formatted RFC3339 string."
  [years months days hours minutes seconds nanoseconds
   offset-sign offset-hours offset-minutes]
  ;; Build RFC3339 string, then wrap in Date class instance
  (let [ms (quot nanoseconds 1000000)
        offset-str (if (and (zero? offset-sign) (zero? offset-hours) (zero? offset-minutes))
                     "Z"
                     (str (if (neg? offset-sign) "-" "+")
                          (format "%02d:%02d" offset-hours offset-minutes)))
        s (if (pos? ms)
            (str (format "%04d-%02d-%02dT%02d:%02d:%02d" years months days hours minutes seconds)
                 "." (format "%03d" ms) offset-str)
            (str (format "%04d-%02d-%02dT%02d:%02d:%02d" years months days hours minutes seconds)
                 offset-str))]
    (__inst-from-string s)))

(defn read-instant-date
  "To read an instant as a date, bind *data-readers* to a map with
this var as the value for the 'inst key. The timezone offset will be used
to convert into UTC."
  [cs]
  (parse-timestamp (validated construct-date) cs))

;; CLJW: read-instant-calendar and read-instant-timestamp not implemented
;; (require Java Calendar/Timestamp types). read-instant-date is the default reader.
