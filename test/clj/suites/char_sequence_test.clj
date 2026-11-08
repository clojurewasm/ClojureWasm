;; [CLJW-CHARSEQ-SEQABLE] clj's RT treats every java.lang.CharSequence alike:
;; RT.seqFrom views it as a StringSeq, RT.countFrom asks its length(), and
;; RT.nthFrom its charAt(); the ^CharSequence clojure.string fns and the regex
;; fns read its characters too. A String is the native one;
;; java.lang.StringBuilder (a host surface) and a deftype declaring
;; CharSequence (the shape of instaparse's Segment) must read the same way,
;; without claiming to be a Clojure collection. Every expected value was
;; checked against clj 1.12.
(ns suites.char-sequence-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]))

(deftype Seg [^String s]
  CharSequence
  (length [_] (count s))
  (charAt [_ i] (.charAt s (int i)))
  (subSequence [_ a b] (Seg. (subs s a b)))
  (toString [_] s))

;; --- java.lang.StringBuilder ---

(deftest string-builder-seq
  (is (= '(\x \y) (seq (StringBuilder. "xy"))))
  (is (nil? (seq (StringBuilder.))))
  (is (= \x (first (StringBuilder. "xy"))))
  (is (nil? (first (StringBuilder.))))
  (is (= '(\y) (rest (StringBuilder. "xy"))))
  (is (nil? (next (StringBuilder. "x"))))
  (is (= [\x \y] (into [] (StringBuilder. "xy"))))
  (is (= '(97 98) (map int (StringBuilder. "ab"))))
  (is (= "ab" (apply str (StringBuilder. "ab"))))
  (is (= {\a 2 \b 1} (frequencies (StringBuilder. "aab"))))
  (is (true? (empty? (StringBuilder.))))
  (is (false? (empty? (StringBuilder. "a")))))

;; A builder is seqed as it stands at `seq` time, after any appends so far.
(deftest string-builder-seq-sees-appends
  (let [sb (StringBuilder. "a")]
    (.append sb "bc")
    (is (= '(\a \b \c) (seq sb)))))

(deftest string-builder-count
  (is (= 2 (count (StringBuilder. "xy"))))
  (is (= 0 (count (StringBuilder.))))
  (is (= 5 (count (StringBuilder. "héllo")))))

(deftest string-builder-nth
  (is (= \y (nth (StringBuilder. "xy") 1)))
  (is (= (char 233) (nth (StringBuilder. "héllo") 1)))
  (is (= :d (nth (StringBuilder. "xy") 5 :d)))
  (is (= :d (nth (StringBuilder. "xy") 2 :d)))
  (is (thrown? Throwable (nth (StringBuilder. "xy") 5))))

(deftest string-builder-is-a-char-sequence
  (is (instance? CharSequence (StringBuilder. "a")))
  (is (instance? java.lang.CharSequence (StringBuilder. "a"))))

;; seq / count / nth reach a builder as a CharSequence, so it must not also
;; answer as a Clojure collection interface (clj: all false).
(deftest string-builder-is-not-a-clojure-collection
  (is (false? (instance? clojure.lang.Seqable (StringBuilder. "a"))))
  (is (false? (instance? clojure.lang.Indexed (StringBuilder. "a"))))
  (is (false? (instance? clojure.lang.IPersistentCollection (StringBuilder. "a"))))
  (is (false? (counted? (StringBuilder. "a"))))
  (is (false? (coll? (StringBuilder. "a"))))
  (is (false? (sequential? (StringBuilder. "a")))))

;; The CharSequence members themselves, indexed by codepoint like String.
(deftest string-builder-char-sequence-methods
  (is (= 5 (.length (StringBuilder. "héllo"))))
  (is (= (char 233) (.charAt (StringBuilder. "héllo") 1)))
  (is (= "el" (.subSequence (StringBuilder. "hello") 1 3)))
  (is (= "él" (.subSequence (StringBuilder. "héllo") 1 3)))
  (is (= "el" (.substring (StringBuilder. "hello") 1 3)))
  (is (= "ello" (.substring (StringBuilder. "hello") 1)))
  (is (thrown? Throwable (.subSequence (StringBuilder. "hello") 3 9))))

;; --- a deftype declaring java.lang.CharSequence ---

(deftest deftype-char-sequence-reads-like-a-string
  (let [g (Seg. "xyz")]
    (is (= '(\x \y \z) (seq g)))
    (is (nil? (seq (Seg. ""))))
    (is (= \x (first g)))
    (is (= 3 (count g)))
    (is (= \y (nth g 1)))
    (is (= :d (nth g 9 :d)))
    (is (= [\x \y \z] (into [] g)))))

(deftest deftype-char-sequence-membership
  (let [g (Seg. "xyz")]
    (is (instance? CharSequence g))
    (is (instance? java.lang.CharSequence g))))

;; --- clojure.string and the regex fns over a CharSequence ---
;; clj hints these ^CharSequence and calls CharSequence methods on the
;; argument (or hands it to a Matcher), so any CharSequence reads as its text.

(deftest string-builder-clojure-string
  (is (true? (str/blank? (StringBuilder. "  "))))
  (is (false? (str/blank? (StringBuilder. " x "))))
  (is (true? (str/blank? (StringBuilder.))))
  (is (= "a b" (str/trim (StringBuilder. "  a b  "))))
  (is (= "a  " (str/triml (StringBuilder. "  a  "))))
  (is (= "  a" (str/trimr (StringBuilder. "  a  "))))
  (is (= "a" (str/trim-newline (StringBuilder. "a\r\n"))))
  (is (= "cba" (str/reverse (StringBuilder. "abc"))))
  (is (= ["a" "b"] (str/split (StringBuilder. "a,b") #",")))
  (is (= ["a" "b,c"] (str/split (StringBuilder. "a,b,c") #"," 2)))
  (is (= ["a" "b"] (str/split-lines (StringBuilder. "a\nb"))))
  (is (= "a&lt;b" (str/escape (StringBuilder. "a<b") {\< "&lt;"}))))

(deftest string-builder-regex
  (is (= "bb" (re-find #"b+" (StringBuilder. "abbc"))))
  (is (= ["ab" "b"] (re-find #"a(b)" (StringBuilder. "xab"))))
  (is (= '("1" "2") (re-seq #"[0-9]" (StringBuilder. "a1b2"))))
  (is (nil? (re-seq #"a" (StringBuilder.))))
  (is (= "abc" (re-matches #"a.c" (StringBuilder. "abc"))))
  (is (nil? (re-matches #"a.c" (StringBuilder. "abcd")))))

(deftest deftype-char-sequence-clojure-string-and-regex
  (is (= "yz" (re-find #"[yz]+" (Seg. "xyz"))))
  (is (false? (str/blank? (Seg. "xyz"))))
  (is (true? (str/blank? (Seg. "  "))))
  (is (= "x" (str/trim (Seg. " x ")))))

;; A value that is not a CharSequence is still refused, as clj's cast refuses it.
(deftest non-char-sequence-is-refused
  (is (true? (str/blank? nil)))
  (is (thrown? ClassCastException (str/blank? 42)))
  (is (thrown? ClassCastException (str/trim 42)))
  (is (thrown? ClassCastException (str/reverse 42)))
  (is (thrown? ClassCastException (str/split 42 #",")))
  (is (thrown? ClassCastException (re-find #"a" 42)))
  (is (thrown? ClassCastException (re-matches #"a" 42)))
  (is (thrown? ClassCastException (re-seq #"a" 42))))
