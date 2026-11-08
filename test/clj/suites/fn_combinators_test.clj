;; test/e2e/phase14_fn_combinators.sh
;;
;; D-134 missing-core batch — fn combinators: some-fn / every-pred /
;; trampoline / replace (Pattern A `.clj` over primitives). These ride the
;; AOT-bootstrap blob (ADR-0056): core.clj is build-time bytecode-compiled,
;; so a passing run also confirms these new fns AOT-restore faithfully
;; (incl. loop/recur in some-fn + multi-arity self-recursive trampoline).

;; Migrated from test/e2e/phase14_fn_combinators.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.fn-combinators-test
  (:require [clojure.test :refer [deftest is]]))

(deftest fn-combinators-cases
  (is (= "false" (pr-str ((some-fn even? neg?) 3))) "somefn_none")
  (is (= "true" (pr-str ((some-fn even? neg?) 4))) "somefn_first")
  (is (= "true" (pr-str ((some-fn even? neg?) -3))) "somefn_later")
  (is (= "true" (pr-str ((every-pred pos? even?) 4))) "everyp_all")
  (is (= "false" (pr-str ((every-pred pos? even?) 3))) "everyp_odd")
  (is (= "false" (pr-str ((every-pred pos? even?) -4))) "everyp_neg")
  (is (= "42" (pr-str (trampoline (fn* [] 42)))) "tramp_direct")
  (is (= "7" (pr-str (trampoline (fn* [] (fn* [] (fn* [] 7)))))) "tramp_bounce")
  (is (= "[1 2 :c 1]" (pr-str (replace {:a 1 :b 2} [:a :b :c :a]))) "replace_vec")
  (is (= "[1 :two 3 :two]" (pr-str (vec (replace {2 :two} (list 1 2 3 2))))) "replace_seq"))
