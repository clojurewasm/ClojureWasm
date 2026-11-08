;; test/e2e/phase7_apply_variadic.sh
;;
;; Phase 7 §9.9 row 7.9 — `apply` variadic-callee bind-direct fast-path
;; (D-072, ADR-0042).
;;
;; The ADR-0042 gate fires when:
;;   - callee f.tag() == .fn_val
;;   - f.variadic != null AND f.variadic.arity == leading.len
;;   - trailing tag in {.list, .cons, .chunked_cons, .lazy_seq, .nil}
;; applyFn then passes args[1..] = [leading..., trailing] straight
;; through; callFunction's rest-pack gate binds trailing to the
;; `& rest` slot without realising or cons-wrapping. Other shapes
;; (fixed-arity callee, builtin, keyword-as-fn, vector / non-seq
;; trailing) take the eager-spread fallback.
;;
;; Diff_test (`src/lang/diff_test.zig`) locks the equivalence on
;; both backends; this e2e exercises the CLI surface.

;; Migrated from test/e2e/phase7_apply_variadic.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.apply-variadic-test
  (:require [clojure.test :refer [deftest is]]))

(deftest apply-variadic-cases
  (is (= "5" (pr-str (apply (fn* [& xs] (count xs)) '(1 2 3 4 5)))) "bind_direct_list_no_leading")
  (is (= "3" (pr-str (apply (fn* [a b & xs] (count xs)) 10 20 '(3 4 5)))) "bind_direct_list_with_leading")
  (is (= "99" (pr-str (apply (fn* [& xs] (first xs)) '(99 100 101)))) "bind_direct_first_through_rest")
  (is (= "5" (pr-str (apply (fn* [& xs] (count xs)) [1 2 3 4 5]))) "vector_tail_spread")
  (is (= "15" (pr-str (apply + 1 2 '(3 4 5)))) "builtin_apply_list_tail")
  (is (= "10" (pr-str (apply (fn* [a b c d] (+ a b c d)) 1 '(2 3 4)))) "fixed_arity_apply_list_tail")
  (is (= "0" (pr-str (apply (fn* [& xs] (count xs)) nil))) "bind_direct_nil_empty_rest")
  (is (= "4" (pr-str (apply (fn* [a & xs] (count xs)) '(10 20 30 40 50)))) "gate_miss_arity_mismatch_eager"))
