;; test/e2e/phase14_string_getbytes.sh — (.getBytes s [charset]) (D-425). UTF-8
;; bytes of s as a cljw byte .array of SIGNED-byte ints (clj byte[] parity: a
;; byte > 127 is negative). cljw is UTF-8-only; a charset arg is accepted, UTF-8
;; always used. (String. bytes) + StandardCharsets are a follow-up.

;; Migrated from test/e2e/phase14_string_getbytes.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.string-getbytes-test
  (:require [clojure.test :refer [deftest is]]))

(deftest string-getbytes-cases
  (is (= "(97 98 99)" (pr-str (seq (.getBytes "abc")))) "ascii")
  (is (= "(-61 -87)" (pr-str (seq (.getBytes "é")))) "utf8_signed")
  (is (= "3" (pr-str (alength (.getBytes "abc")))) "is_array")
  (is (= "[104 105]" (pr-str (vec (.getBytes "hi" "UTF-8")))) "charset_arg")
  (is (= "nil" (pr-str (seq (.getBytes "")))) "empty")
  (is (= "88" (pr-str (aget (.getBytes "Xyz") 0))) "aget0")
  (is (= "\"hello\"" (pr-str (String. (.getBytes "hello")))) "from_bytes")
  (is (= "true" (pr-str (= "café" (String. (.getBytes "café"))))) "roundtrip_utf8")
  (is (= "\"\"" (pr-str (String.))) "string_empty")
  (is (= "\"x\"" (pr-str (String. "x"))) "string_copy")
  (is (= "\"hi\"" (pr-str (String. (.getBytes "hi") "UTF-8"))) "from_bytes_charset"))
