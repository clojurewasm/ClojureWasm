;; test/e2e/phase7_symbol_value.sh
;;
;; Phase 7 entry T2 (ADR-0037) smoke — Symbol heap Value impl
;; behind F-004 Group A slot 1. Asserts user-visible surface:
;;   - (quote sym) evaluates without raising; pr-str renders with no
;;     leading colon (distinct from keyword's `:foo`).
;;   - (name 'ns/x) extracts the bare name.
;;   - (symbol "foo") constructs; (symbol "ns" "name") constructs
;;     qualified; both round-trip.
;;   - (symbol? 'foo) is true; (symbol? :foo) is false (tag-dispatch
;;     keeps symbol and keyword distinct).
;;   - (keyword 'foo) and (symbol :foo) cross-convert via the
;;     extended 1-arg surface.
;;
;; `(= 'foo 'foo)` is intentionally NOT exercised here: cw v1's `=`
;; primitive is numeric-only (per math.zig:230 docstring — Phase 2
;; limitation; finished-form `=` lands when collection equality
;; arrives). Pointer-eq interning IS verified — by the differential
;; test `symbol_quote_roundtrip` in src/lang/diff_test.zig, which
;; checks both backends intern the same `(ns, name)` to the same
;; heap pointer via `analyzeQuote`'s call into `formToValue`.

;; Migrated from test/e2e/phase7_symbol_value.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.symbol-value-test
  (:require [clojure.test :refer [deftest is]]))

(deftest symbol-value-cases
  (is (= "foo" (pr-str (quote foo))) "quote_bare")
  (is (= "ns/bar" (pr-str (quote ns/bar))) "quote_qualified")
  (is (= "\"foo\"" (pr-str (name (quote foo)))) "name_bare")
  (is (= "\"x\"" (pr-str (name (quote ns/x)))) "name_qualified")
  (is (= "foo" (pr-str (symbol "foo"))) "symbol_1arg_string")
  (is (= "ns/name" (pr-str (symbol "ns" "name"))) "symbol_2arg")
  (is (= "foo" (pr-str (symbol (quote foo)))) "symbol_idempotent")
  (is (= "true" (pr-str (symbol? (quote foo)))) "symbol_q_yes")
  (is (= "false" (pr-str (symbol? 42))) "symbol_q_no")
  (is (= "false" (pr-str (symbol? :foo))) "symbol_q_kw")
  (is (= "false" (pr-str (symbol? "foo"))) "symbol_q_str")
  (is (= "foo" (pr-str (symbol :foo))) "symbol_from_keyword")
  (is (= ":foo" (pr-str (keyword (quote foo)))) "keyword_from_symbol"))
