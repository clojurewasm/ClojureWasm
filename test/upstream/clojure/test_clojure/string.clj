;; Upstream: clojure/test/clojure/test_clojure/string.clj
;; Upstream lines: 197
;; CLJW markers: 6

;; CLJW: ns form simplified — removed *warn-on-reflection*
(ns clojure.test-clojure.string
  (:require [clojure.string :as s])
  (:use clojure.test))

(deftest t-split
  (is (= ["a" "b"] (s/split "a-b" #"-")))
  (is (= ["a" "b-c"] (s/split "a-b-c" #"-" 2)))
  (is (vector? (s/split "abc" #"-"))))

(deftest t-reverse
  (is (= "tab" (s/reverse "bat"))))

(deftest t-replace
  (is (= "faabar" (s/replace "foobar" \o \a)))
  (is (= "foobar" (s/replace "foobar" \z \a)))
  (is (= "barbarbar" (s/replace "foobarfoo" "foo" "bar")))
  (is (= "foobarfoo" (s/replace "foobarfoo" "baz" "bar")))
  (is (= "f$$d" (s/replace "food" "o" "$")))
  (is (= "f\\\\d" (s/replace "food" "o" "\\")))
  (is (= "barbarbar" (s/replace "foobarfoo" #"foo" "bar")))
  (is (= "foobarfoo" (s/replace "foobarfoo" #"baz" "bar")))
  (is (= "f$$d" (s/replace "food" #"o" (s/re-quote-replacement "$"))))
  (is (= "f\\\\d" (s/replace "food" #"o" (s/re-quote-replacement "\\"))))
  (is (= "FOObarFOO" (s/replace "foobarfoo" #"foo" s/upper-case)))
  (is (= "foobarfoo" (s/replace "foobarfoo" #"baz" s/upper-case)))
  (is (= "OObarOO" (s/replace "foobarfoo" #"f(o+)" (fn [[m g1]] (s/upper-case g1)))))
  (is (= "baz\\bang\\" (s/replace "bazslashbangslash" #"slash" (constantly "\\")))))

(deftest t-replace-first
  (is (= "faobar" (s/replace-first "foobar" \o \a)))
  (is (= "foobar" (s/replace-first "foobar" \z \a)))
  (is (= "z.ology" (s/replace-first "zoology" \o \.)))
  (is (= "barbarfoo" (s/replace-first "foobarfoo" "foo" "bar")))
  (is (= "foobarfoo" (s/replace-first "foobarfoo" "baz" "bar")))
  (is (= "f$od" (s/replace-first "food" "o" "$")))
  (is (= "f\\od" (s/replace-first "food" "o" "\\")))
  (is (= "barbarfoo" (s/replace-first "foobarfoo" #"foo" "bar")))
  (is (= "foobarfoo" (s/replace-first "foobarfoo" #"baz" "bar")))
  (is (= "f$od" (s/replace-first "food" #"o" (s/re-quote-replacement "$"))))
  (is (= "f\\od" (s/replace-first "food" #"o" (s/re-quote-replacement "\\"))))
  (is (= "FOObarfoo" (s/replace-first "foobarfoo" #"foo" s/upper-case)))
  (is (= "foobarfoo" (s/replace-first "foobarfoo" #"baz" s/upper-case)))
  (is (= "OObarfoo" (s/replace-first "foobarfoo" #"f(o+)" (fn [[m g1]] (s/upper-case g1)))))
  (is (= "baz\\bangslash" (s/replace-first "bazslashbangslash" #"slash" (constantly "\\")))))

(deftest t-join
  (are [x coll] (= x (s/join coll))
    "" nil
    "" []
    "1" [1]
    "12" [1 2])
  (are [x sep coll] (= x (s/join sep coll))
    "1,2,3" \, [1 2 3]
    "" \, []
    "1" \, [1]
    "1 and-a 2 and-a 3" " and-a " [1 2 3]))

(deftest t-trim-newline
  (is (= "foo" (s/trim-newline "foo\n")))
  (is (= "foo" (s/trim-newline "foo\r\n")))
  (is (= "foo" (s/trim-newline "foo")))
  (is (= "" (s/trim-newline ""))))

(deftest t-capitalize
  (is (= "Foobar" (s/capitalize "foobar")))
  (is (= "Foobar" (s/capitalize "FOOBAR"))))

(deftest t-triml
  (is (= "foo " (s/triml " foo ")))
  (is (= "" (s/triml "   ")))
  (is (= "bar" (s/triml "\u2002 \tbar"))))

(deftest t-trimr
  (is (= " foo" (s/trimr " foo ")))
  (is (= "" (s/trimr "   ")))
  (is (= "bar" (s/trimr "bar\t \u2002"))))

(deftest t-trim
  (is (= "foo" (s/trim "  foo  \r\n")))
  (is (= "bar" (s/trim "\u2000bar\t \u2002"))))

(deftest t-upper-case
  (is (= "FOOBAR" (s/upper-case "Foobar"))))

(deftest t-lower-case
  (is (= "foobar" (s/lower-case "FooBar"))))

;; CLJW: NullPointerException → Exception (our error system throws type errors on nil)
(deftest nil-handling
  (are [f args] (thrown? Exception (apply f args))
    s/reverse [nil]
    s/replace [nil #"foo" "bar"]
    s/replace-first [nil #"foo" "bar"]
    s/re-quote-replacement [nil]
    s/capitalize [nil]
    s/upper-case [nil]
    s/lower-case [nil]
    s/split [nil #"-"]
    s/split [nil #"-" 1]
    s/trim [nil]
    s/triml [nil]
    s/trimr [nil]
    s/trim-newline [nil]))

;; CLJW: char-sequence-handling test skipped — StringBuffer is JVM interop
;; Upstream tests CharSequence/StringBuffer coercion for all string fns.
;; Our functions accept strings directly; no CharSequence abstraction.

(deftest t-escape
  (is (= "&lt;foo&amp;bar&gt;"
         (s/escape "<foo&bar>" {\& "&amp;" \< "&lt;" \> "&gt;"})))
  (is (= " \\\"foo\\\" "
         (s/escape " \"foo\" " {\" "\\\""})))
  (is (= "faabor"
         (s/escape "foobar" {\a \o, \o \a}))))

(deftest t-blank
  (is (s/blank? nil))
  (is (s/blank? ""))
  (is (s/blank? " "))
  (is (s/blank? " \t \n  \r "))
  (is (not (s/blank? "  foo  "))))

(deftest t-split-lines
  (let [result (s/split-lines "one\ntwo\r\nthree")]
    (is (= ["one" "two" "three"] result))
    (is (vector? result)))
  (is (= (list "foo") (s/split-lines "foo"))))

;; CLJW: StringBuffer → plain string (no JVM CharSequence)
(deftest t-index-of
  (let [sb "tacos"]
    (is (= 2  (s/index-of sb "c")))
    (is (= 2  (s/index-of sb \c)))
    (is (= 1  (s/index-of sb "ac")))
    (is (= 3  (s/index-of sb "o" 2)))
    (is (= 3  (s/index-of sb  \o  2)))
    (is (= 3  (s/index-of sb "o" -100)))
    (is (= nil (s/index-of sb "z")))
    (is (= nil (s/index-of sb \z)))
    (is (= nil (s/index-of sb "z" 2)))
    (is (= nil (s/index-of sb \z  2)))
    (is (= nil (s/index-of sb "z" 100))
        (is (= nil (s/index-of sb "z" -10))))))

;; CLJW: StringBuffer → plain string (no JVM CharSequence)
(deftest t-last-index-of
  (let [sb "banana"]
    (is (= 4 (s/last-index-of sb "n")))
    (is (= 4 (s/last-index-of sb \n)))
    (is (= 3 (s/last-index-of sb "an")))
    (is (= 4 (s/last-index-of sb "n")))
    (is (= 4 (s/last-index-of sb "n" 5)))
    (is (= 4 (s/last-index-of sb \n  5)))
    (is (= 4 (s/last-index-of sb "n" 500)))
    (is (= nil (s/last-index-of sb "z")))
    (is (= nil (s/last-index-of sb "z" 1)))
    (is (= nil (s/last-index-of sb \z  1)))
    (is (= nil (s/last-index-of sb "z" 100))
        (is (= nil (s/last-index-of sb "z" -10))))))

(deftest t-starts-with?
  (is (s/starts-with? "clojure west" "clojure"))
  (is (not (s/starts-with? "conj" "clojure"))))

(deftest t-ends-with?
  (is (s/ends-with? "Clojure West" "West")
      (is (not (s/ends-with? "Conj" "West")))))

(deftest t-includes?
  (let [sb "Clojure Applied Book"]
    (is (s/includes? sb "Applied"))
    (is (not (s/includes? sb "Living")))))

(deftest empty-collections
  (is (= "()" (str ())))
  (is (= "{}" (str {})))
  (is (= "[]" (str []))))

;; CLJW-ADD: test runner invocation
(run-tests)
