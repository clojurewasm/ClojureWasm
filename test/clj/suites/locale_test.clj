;; test/e2e/phase14_locale.sh
;;
;; java.util.Locale/US + /ROOT object-valued static-field singletons + the
;; String.toUpperCase/toLowerCase 2-arg Locale overload (ignored — cljw casing is
;; locale-independent) + (.sym keyword). All landed for honeysql (ADR-0115).

;; Migrated from test/e2e/phase14_locale.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.locale-test
  (:require [clojure.test :refer [deftest is]]))

(deftest locale-cases
  (is (= "\"en_US\"" (pr-str (str java.util.Locale/US))) "locale_us_str")
  (is (= "\"\"" (pr-str (str java.util.Locale/ROOT))) "locale_root_str")
  (is (= "true" (pr-str (identical? java.util.Locale/US java.util.Locale/US))) "locale_identity")
  (is (= "true" (pr-str (instance? java.util.Locale java.util.Locale/US))) "locale_instance")
  (is (= "\"ABC\"" (pr-str (.toUpperCase "abc" java.util.Locale/US))) "upper_locale")
  (is (= "\"abc\"" (pr-str (.toLowerCase "ABC" java.util.Locale/ROOT))) "lower_locale")
  (is (= "\"ABC\"" (pr-str (.toUpperCase "abc"))) "upper_1arg")
  (is (= "\"foo\"" (pr-str (str (.sym :foo)))) "sym_simple")
  (is (= "\"a/b\"" (pr-str (str (.sym :a/b)))) "sym_qual")
  (is (= "true" (pr-str (symbol? (.sym :x)))) "sym_is_sym"))
