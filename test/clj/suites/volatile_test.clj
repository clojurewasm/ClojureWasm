;; test/e2e/phase14_volatile.sh — volatile! / vreset! / vswap! / volatile?
;; (unsynchronized mutable box; atom minus CAS/watch). Corpus gap sweep P0.

;; Migrated from test/e2e/phase14_volatile.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.volatile-test
  (:require [clojure.test :refer [deftest is]]))

(deftest volatile-cases
  (is (= "7" (pr-str @(volatile! 7))) "deref_at")
  (is (= "5" (pr-str (deref (volatile! 5)))) "deref_fn")
  (is (= "9" (pr-str (let [v (volatile! 0)] (vreset! v 9) @v))) "vreset")
  (is (= "3" (pr-str (vreset! (volatile! 0) 3))) "vreset_r")
  (is (= "1" (pr-str (let [v (volatile! 0)] (vswap! v inc) @v))) "vswap")
  (is (= "111" (pr-str (vswap! (volatile! 1) + 10 100))) "vswap_arg")
  (is (= "true" (pr-str (volatile? (volatile! 0)))) "volQ_t")
  (is (= "false" (pr-str (volatile? (atom 0)))) "volQ_atom")
  (is (= "false" (pr-str (volatile? 5))) "volQ_n"))
