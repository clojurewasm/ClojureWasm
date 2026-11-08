;; test/e2e/phase14_short_byte.sh
;;
;; D-295 — java.lang.Short / java.lang.Byte MIN_VALUE / MAX_VALUE static fields
;; (ADR-0061 static-field pattern, mirroring Integer/Long). cljw has no short/byte
;; primitive type (F-005), so these are plain Long constants. Used by
;; clojure.data.generators' short/byte range generators.

;; Migrated from test/e2e/phase14_short_byte.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.short-byte-test
  (:require [clojure.test :refer [deftest is]]))

(deftest short-byte-cases
  (is (= "32767" (pr-str Short/MAX_VALUE)) "short_max")
  (is (= "-32768" (pr-str Short/MIN_VALUE)) "short_min")
  (is (= "127" (pr-str Byte/MAX_VALUE)) "byte_max")
  (is (= "-128" (pr-str Byte/MIN_VALUE)) "byte_min")
  (is (= "32768" (pr-str (inc (long Short/MAX_VALUE)))) "short_arith"))
