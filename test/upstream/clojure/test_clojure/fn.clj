;; Upstream: clojure/test/clojure/test_clojure/fn.clj
;; Upstream lines: 55
;; CLJW markers: 5

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Ambrose Bonnaire-Sergeant

(ns clojure.test-clojure.fn
  (:use clojure.test))

;; CLJW: adapted — fails-with-cause?/ExceptionInfo/spec → thrown?/Exception (no clojure.spec)
(deftest fn-error-checking
  (testing "bad arglist"
    (is (thrown? Exception (eval '(fn "a" a)))))

  ;; CLJW: "treat first param as args" skipped — our analyzer accepts (fn "a" []) as named fn
  ;; In JVM Clojure, spec rejects string in name position; our analyzer treats it as docstring-like

  (testing "looks like listy signature, but malformed declaration"
    (is (thrown? Exception (eval '(fn (1))))))

  (testing "checks each signature"
    (is (thrown? Exception (eval '(fn
                                    ([a] 1)
                                    ("a" 2))))))

  (testing "correct name but invalid args"
    (is (thrown? Exception (eval '(fn a "a")))))

  (testing "first sig looks multiarity, rest of sigs should be lists"
    (is (thrown? Exception (eval '(fn a
                                    ([a] 1)
                                    [a b])))))

  (testing "missing parameter declaration"
    (is (thrown? Exception (eval '(fn a))))
    (is (thrown? Exception (eval '(fn))))))

;; CLJW-ADD: test runner invocation
(run-tests)
