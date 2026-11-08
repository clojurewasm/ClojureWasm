;; test/e2e/phase6_16_c_keyword_name.sh
;;
;; Phase 6.16.c Group C-prereq — `keyword` + `name` Tier-A
;; primitives. v5 §9.1. Needed by `keywordize-keys` +
;; `stringify-keys` (Group C).

;; Migrated from test/e2e/phase6_16_c_keyword_name.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.keyword-name-test
  (:require [clojure.test :refer [deftest is]]))

(deftest keyword-name-cases
  (is (= ":foo" (pr-str (keyword "foo"))) "keyword_from_string")
  (is (= ":already" (pr-str (keyword :already))) "keyword_idempotent")
  (is (= "nil" (pr-str (keyword nil))) "keyword_nil_passthrough")
  (is (= ":ns/name" (pr-str (keyword "ns" "name"))) "keyword_qualified")
  (is (= "\"hello\"" (pr-str (name :hello))) "name_of_keyword")
  (is (= "\"foo\"" (pr-str (name :my.ns/foo))) "name_of_qualified_keyword")
  (is (= "\"hi\"" (pr-str (name "hi"))) "name_of_string")
  (is (= "\"x\"" (pr-str (name (keyword "x")))) "roundtrip_keyword_name")
  (is (= "\"my.ns\"" (pr-str (namespace :my.ns/foo))) "namespace_qualified_keyword")
  (is (= "nil" (pr-str (namespace :foo))) "namespace_unqualified_nil")
  (is (= "\"a\"" (pr-str (namespace 'a/b))) "namespace_qualified_symbol")
  (is (= "nil" (pr-str (namespace 'x))) "namespace_unqualified_symbol_nil"))
