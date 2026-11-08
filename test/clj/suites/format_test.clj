;; clojure.core/format — the printf subset (D-134, D-216, D-470).
;;
;; Migrated from test/e2e/phase14_format.sh and
;; test/e2e/phase14_format_char_int.sh. Value and error contracts now run in
;; one native clojure.test process, including the intentional AD-029 %c pin.
;;
;; Run by `test/clj/run_suites.clj` — one cljw process for the whole file,
;; instead of one process per assertion the way the bash e2e tier works.
(ns suites.format-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string :as str]))

;; --- conversions: %s %d %f %x + the no-arg %% ---
(deftest conversions
  (is (= "hello" (format "hello")))
  (is (= "3 items" (format "%d items" 3)))
  (is (= "x = 42" (format "%s = %d" "x" 42)))
  (testing "%f defaults to 6 fractional digits; precision rounds"
    (is (= "1.500000" (format "%f" 1.5)))
    (is (= "3.14" (format "%.2f" 3.14159)))
    (is (= "4" (format "%.0f" 3.7))))
  (is (= "ff" (format "%x" 255)))
  (is (= "100%" (format "100%%")))
  (is (= ":a/:b" (format "%s/%s" :a :b)))
  (is (= "1-2-3" (format "%d-%d-%d" 1 2 3))))

;; --- width / justification / zero-pad flags ---
(deftest width-and-flags
  (testing "width space-pads, `-` left-justifies"
    (is (= "[    3]" (format "[%5d]" 3)))
    (is (= "[3    ]" (format "[%-5d]" 3)))
    (is (= "[        hi]" (format "[%10s]" "hi")))
    (is (= "[hi        ]" (format "[%-10s]" "hi")))
    (is (= "[    3.14]" (format "[%8.2f]" 3.14159))))
  (testing "zero-pad: sign stays leftmost, `-` overrides `0` (clj-verified)"
    (is (= "00042" (format "%05d" 42)))
    (is (= "-0042" (format "%05d" -42)))
    (is (= "[42   ]" (format "[%-05d]" 42)))
    (is (= "00ff" (format "%04x" 255))))
  (testing "a value wider than the field is never truncated"
    (is (= "[12345]" (format "[%3d]" 12345)))))

;; --- %n newline directive (count + split prove a real \n) ---
(deftest newline-directive
  (is (= 3 (count (format "x%ny"))))
  (is (= ["x" "y"] (vec (str/split (format "x%ny") #"\n")))))

;; --- integer conversions X / o + sign flags (+, space, parens) + grouping ---
(deftest integer-conversions
  (is (= "FF" (format "%X" 255)))
  (is (= "10" (format "%o" 8)))
  (testing "sign flags"
    (is (= "+42" (format "%+d" 42)))
    (is (= " 42" (format "% d" 42)))
    (is (= "(5)" (format "%(d" -5))))
  (testing "grouping"
    (is (= "1,000,000" (format "%,d" 1000000)))
    (is (= "-1,234,567" (format "%,d" -1234567))))
  (testing "flag combinations"
    (is (= "+0042" (format "%+05d" 42)))
    (is (= "00000001,000" (format "%,012d" 1000)))))

;; --- scientific %e / %E (default precision 6; exponent is sign + >=2 digits) ---
(deftest scientific
  (is (= "1.234568e+04" (format "%e" 12345.678)))
  (is (= "1.23e+04" (format "%.2e" 12345.678)))
  (is (= "1.234568E+04" (format "%E" 12345.678)))
  (is (= "-5.500000e+00" (format "%e" -5.5)))
  (is (= "1.230000e-04" (format "%e" 0.000123)))
  (is (= "0.000000e+00" (format "%e" 0.0)))
  (is (= "1.000000e+00" (format "%e" 1.0))))

;; --- general %g / %G (P sig figs; fixed when -4<=exp<P else scientific) ---
(deftest general-float
  (is (= "0.000123400" (format "%g" 0.0001234)))
  (is (= "123456" (format "%g" 123456.0)))
  (is (= "1.23457e+06" (format "%g" 1234567.0)))
  (is (= "0.00000" (format "%g" 0.0)))
  (is (= "1.23e+05" (format "%.3g" 123456.0)))
  (is (= "1.00000e-05" (format "%g" 0.00001)))
  (is (= "1.23457E+06" (format "%G" 1234567.0)))
  (is (= "-42.5000" (format "%g" -42.5))))

;; --- D-216: completed flag/conversion surface (clj-parity) ---
(deftest heap-long-and-unsigned
  (testing "heap-Long operands (D-165)"
    (is (= "1000000000000000" (format "%d" 1000000000000000)))
    (is (= "1,000,000,000,000,000" (format "%,d" 1000000000000000))))
  (testing "%x renders a negative long as unsigned 64-bit"
    (is (= "ffffffffffffffff" (format "%x" -1))))
  (testing "# alternate form"
    (is (= "0xff" (format "%#x" 255)))
    (is (= "0XFF" (format "%#X" 255)))
    (is (= "0100" (format "%#o" 64)))))

(deftest float-sign-and-group-flags
  (is (= "+3.14" (format "%+.2f" 3.14)))
  (is (= " 3.14" (format "% .2f" 3.14)))
  (is (= "(3.14)" (format "%(.2f" -3.14)))
  (is (= "1,234,567.50" (format "%,.2f" 1234567.5)))
  (is (= "+1.234500e+03" (format "%+e" 1234.5))))

(deftest string-conversions
  (testing "%s nil renders \"null\"; %S upper-cases"
    (is (= "null" (format "%s" nil)))
    (is (= "HI" (format "%S" "hi"))))
  (testing "%.Ns truncates, width still applies"
    (is (= "hel" (format "%.3s" "hello")))
    (is (= "     hel|" (format "%8.3s|" "hello")))))

(deftest character-conversions
  (is (= "A" (format "%c" (char 65))))
  (is (= "A" (format "%c" \A)))
  (is (= "A" (format "%C" \a)))
  (is (= "[  A]" (format "[%3c]" \A)))
  (is (= "[A  ]" (format "[%-3c]" \A)))
  (is (= "null" (format "%c" nil)))
  (is (= "NULL" (format "%C" nil)))
  ;; D-267/AD-029: cljw has one integer type, so it cannot preserve JVM
  ;; Integer-accepted versus Long-rejected behavior. Reject both consciously.
  (is (thrown? Throwable (format "%c" (int 65))))
  (is (thrown? Throwable (format "%c" 65)))
  (is (thrown? Throwable (format "%.1c" \A))))

;; %h/%H render hex of the single-system hasheq (AD-009): hex((hash "abc")) =
;; hex(74834163). clj's %h renders Java String.hashCode ("17862") instead —
;; this is the accepted divergence, asserted here as cljw's behaviour.
(deftest hash-conversion
  (is (= "475e0f3" (format "%h" "abc")))
  (is (= "475E0F3" (format "%H" "abc")))
  (is (= "null" (format "%h" nil))))

;; --- %t date/time family (D-470). AD-052 pins: UTC + English names +
;; "+0000" zone (cljw ships no tz/locale database; matches a TZ=UTC/en JVM). ---
(deftest date-time-family
  (is (= "2009-02-13 23:31:30" (format "%tF %tT" 1234567890123 1234567890123)))
  (is (= "1970/01/01 00:00:00.000"
         (format "%tY/%tm/%td %tH:%tM:%tS.%tL" 0 0 0 0 0 0 0)))
  (is (= "Thu Thursday Jan January am +0000 UTC"
         (format "%ta %tA %tb %tB %tp %tz %tZ" 0 0 0 0 0 0 0)))
  (is (= "02/13/09|11:31:30 PM|044|1234567890|1234567890123"
         (format "%tD|%tr|%tj|%ts|%tQ"
                 1234567890123 1234567890123 1234567890123
                 1234567890123 1234567890123)))
  (testing "a java.util.Date argument"
    (is (= "1970-01-02" (format "%tF" (java.util.Date. 86400000)))))
  (testing "%T upper-cases the whole rendering"
    (is (= "THURSDAY" (format "%TA" 0))))
  (testing "an unknown %t sub-directive throws"
    (is (thrown-with-msg? Throwable #"unsupported directive" (format "%tq" 0)))))

;; --- errors (the bash asserted these substrings on stderr; the same text is
;; the thrown exception's message, so the assertion survives intact) ---
(deftest errors
  (is (thrown-with-msg? Throwable #"expected an integer" (format "%d" "x")))
  #_{:clj-kondo/ignore [:format]}
  (is (thrown-with-msg? Throwable #"not enough arguments" (format "%d")))
  (is (thrown-with-msg? Throwable #"unsupported directive" (format "%q" 1)))
  #_{:clj-kondo/ignore [:type-mismatch]}
  (is (thrown-with-msg? Throwable #"expected string" (format 42))))
