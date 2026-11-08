;; `eval` and the collector. eval analysed into a per-call arena that was freed
;; on return, while a fn the eval'd form def'd kept its bytecode chunks there;
;; the next ordinary threshold collect traced the freed constant pools (a GPF or
;; a segfault at 0x0). Found through clojure-elisp, whose compiler evals user
;; macros on the host. No torture mode needed: the large allocation below
;; crosses the collect threshold on its own. The alloc-torture twin lives in
;; test/clj/torture/rooting_regressions.clj.
(ns suites.eval-gc-test
  (:require [clojure.test :refer [deftest is]]))

(deftest evald-fns-survive-a-threshold-collect
  (binding [*ns* (the-ns 'suites.eval-gc-test)]
    (dotimes [i 20]
      (eval (list 'defn (symbol (str "eval-gc-g" i)) '[x]
                  (list 'str (str "n" i "=") 'x {:a [i] :b #{i}})))))
  (is (= 200000 (count (vec (range 200000)))))
  (is (= "n7=1{:a [7], :b #{7}}" ((resolve 'suites.eval-gc-test/eval-gc-g7) 1)))
  (is (= "n19=2{:a [19], :b #{19}}" ((resolve 'suites.eval-gc-test/eval-gc-g19) 2))))
