;; D-134 int/char coercion primitives, plus the char-literal reader (D-059)
;; and the string-as-char-seq rules (D-174).
;;
;; int: a float truncates toward zero, a char becomes its codepoint, an
;; integer passes through. char: a codepoint becomes a char (0..0x10FFFF).
;;
;; Migrated from test/e2e/phase14_int_char.sh (22 cases). Two things the shell
;; had to work around disappear here:
;;   - It round-tripped every char back through `int` "to avoid shell-escaping
;;     char literals", so `(char 65)` was only ever checked as `65`. A suite
;;     can write `\A` directly, so the char VALUE is asserted.
;;   - Its char-literal cases needed a stdin heredoc plus `head -1` because a
;;     backslash is shell-hostile through `-e`. That machinery is gone.
;; Its two error cases were substring greps over merged output; both raise
;; catchable Kinds (verified 2026-09-09) and now assert the real message.
(ns suites.int-char-test
  (:require [clojure.test :refer [deftest is]]))

;; --- int ---

(deftest int-truncates-toward-zero
  (is (= 3 (int 3.7)))
  (is (= -3 (int -3.7))))

(deftest int-passes-integers-through
  (is (= 5 (int 5))))

(deftest int-of-a-char-is-its-codepoint
  (is (= 66 (int (char 66)))))

;; --- char ---

;; The shell could only check `(int (char 65))`; the char value itself is
;; asserted here.
(deftest char-from-codepoint
  (is (= \A (char 65)))
  (is (= 65 (int (char 65))))
  (is (= 200 (int (char 200)))))

(deftest char-of-a-char-is-idempotent
  (is (= \Z (char (char 90))))
  (is (= 90 (int (char (char 90))))))

(deftest chars-compare-by-value
  (is (= (char 65) (char 65))))

;; --- guarded errors: no ReleaseSafe panic on an out-of-range float or
;; codepoint ---

(deftest int-of-a-non-number-throws
  (is (thrown-with-msg? Throwable #"int: expected number" (int "x"))))

(deftest char-out-of-codepoint-range-throws
  (is (thrown-with-msg? Throwable #"codepoint" (char 9999999999))))

;; --- a string seqs into CHARACTERS, not one-character strings (JVM parity) ---

(deftest first-of-a-string-is-a-char
  (is (char? (first "abc")))
  (is (= \a (first "abc"))))

(deftest mapping-int-over-a-string
  (is (= [97 98 99] (into [] (map int "abc")))))

(deftest frequencies-of-a-string-keys-by-char
  (is (= 2 (get (frequencies "aab") \a))))

;; --- (rest "abc") and (next "abc") are a CHAR-SEQ, not a substring (D-174) ---

(deftest rest-of-a-string-is-a-seq-not-a-string
  (is (false? (string? (rest "abc"))))
  (is (true? (seq? (rest "abc")))))

(deftest rest-of-a-string-yields-chars
  (is (char? (first (rest "abc"))))
  (is (= [\b \c] (into [] (rest "abc"))))
  (is (= [98 99] (into [] (map int (rest "abc"))))))

(deftest next-of-a-string-is-a-seq-not-a-string
  (is (false? (string? (next "abc"))))
  (is (= [98 99] (into [] (map int (next "abc"))))))

;; --- the char-literal reader (D-059): single, terminator, named, octal,
;; UTF-8. Written directly rather than through a stdin heredoc. ---

(deftest char-literals-single-and-terminator
  (is (= [97 65 40 44] [(int \a) (int \A) (int \() (int \,)])))

(deftest char-literals-named
  (is (= [10 32 9 8 13 12]
         [(int \newline) (int \space) (int \tab)
          (int \backspace) (int \return) (int \formfeed)])))

(deftest char-literals-octal-and-utf8
  (is (= 65 (int \o101)))
  (is (= 233 (int \é)))
  (is (= \a (char 97)))
  (is (= "abc" (str \a \b \c))))
