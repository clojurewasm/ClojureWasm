;; test/e2e/phase14_boolean_statics.sh
;;
;; Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
;; java.lang.Boolean statics, completing the java.lang scalar-class static
;; cluster (Integer/Long/Double/Character/Boolean). Surface
;; runtime/java/lang/Boolean.zig.
;;
;; Boolean.parseBoolean is case-INSENSITIVE "true" → true, anything else →
;; false (NOT nil) — distinct from clojure.core/parse-boolean (strict,
;; nil on miss), so it is NOT a delegation. Boolean/TRUE / FALSE are bool
;; static fields (ADR-0061 + the StaticFieldValue.bool extension).

;; Migrated from test/e2e/phase14_boolean_statics.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.boolean-statics-test
  (:require [clojure.test :refer [deftest is]]))

(deftest boolean-statics-cases
  (is (= "true" (pr-str (Boolean/parseBoolean "true"))) "boolean_parse_true")
  (is (= "false" (pr-str (Boolean/parseBoolean "false"))) "boolean_parse_false")
  (is (= "true" (pr-str (Boolean/parseBoolean "TRUE"))) "boolean_parse_caseins")
  (is (= "false" (pr-str (Boolean/parseBoolean "yes"))) "boolean_parse_other_false")
  (is (= "true" (pr-str (Boolean/valueOf "true"))) "boolean_valueOf_string")
  (is (= "false" (pr-str (Boolean/valueOf false))) "boolean_valueOf_bool")
  (is (= "\"true\"" (pr-str (Boolean/toString true))) "boolean_toString_true")
  (is (= "\"false\"" (pr-str (Boolean/toString false))) "boolean_toString_false")
  (is (= "true" (pr-str Boolean/TRUE)) "boolean_true_field")
  (is (= "false" (pr-str Boolean/FALSE)) "boolean_false_field")
  (is (= ":yes" (pr-str (if Boolean/TRUE :yes :no))) "boolean_true_in_expr"))
