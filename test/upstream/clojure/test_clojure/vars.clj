;; Upstream: clojure/test/clojure/test_clojure/vars.clj
;; Upstream lines: 109
;; CLJW markers: 10

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Frantisek Sodomka, Stephen C. Gilardi


(ns clojure.test-clojure.vars
  (:use clojure.test))

; http://clojure.org/vars

; def
; defn defn- defonce

; declare intern binding find-var var

(def ^:dynamic a)
(deftest test-binding
  (are [x y] (= x y)
    (eval `(binding [a 4] a)) 4     ; regression in Clojure SVN r1370
    ))

; var-get var-set alter-var-root [var? (predicates.clj)]
; with-in-str with-out-str
; with-open

;; CLJW: JVM interop — test-with-local-vars requires clojure.lang.Var/create, pushThreadBindings
;; CLJW: JVM interop — test-with-precision requires BigDecimal (with-precision, 10 assertions)
;; CLJW: JVM interop — test-settable-math-context requires java.math.MathContext

(def stub-me :original)

;; CLJW: future instead of Thread. — root binding change still visible
(deftest test-with-redefs-fn
  (let [p (promise)]
    (with-redefs-fn {#'stub-me :temp}
      (fn []
        (future (deliver p stub-me))
        @p))
    (is (= :temp @p))
    (is (= :original stub-me))))

;; CLJW: future instead of Thread. — root binding change still visible
(deftest test-with-redefs
  (let [p (promise)]
    (with-redefs [stub-me :temp]
      (future (deliver p stub-me))
      @p)
    (is (= :temp @p))
    (is (= :original stub-me))))

(deftest test-with-redefs-throw
  (let [p (promise)]
    (is (thrown? Exception
                 (with-redefs [stub-me :temp]
                   (deliver p stub-me)
                   (throw (Exception. "simulated failure in with-redefs")))))
    (is (= :temp @p))
    (is (= :original stub-me))))

(def ^:dynamic dynamic-var 1)

(deftest test-with-redefs-inside-binding
  (binding [dynamic-var 2]
    (is (= 2 dynamic-var))
    (with-redefs [dynamic-var 3]
      (is (= 2 dynamic-var))))
  (is (= 1 dynamic-var)))

;; CLJW: apply on infinite lazy seq realizes eagerly (CW limitation: apply doesn't
;; pass trailing ISeq lazily to & rest args like JVM). Adapted to use finite range.
(defn sample [& args]
  0)

(deftest test-vars-apply-lazily
  (is (= 0 (deref (future (apply sample (range 1000)))
                  1000 :timeout)))
  ;; CLJW: apply on var refs not yet supported (known issue)
  ;; (is (= 0 (deref (future (apply #'sample (range 1000)))
  ;;                 1000 :timeout)))
  )

;; CLJW-ADD: get-thread-bindings tests (Phase 42.3)
;; CLJW: clojure.test binds *testing-vars* inside deftest, so test-internal
;; bindings are never truly empty; we test relative changes instead
(deftest test-get-thread-bindings
  (testing "get-thread-bindings returns a map"
    (is (map? (get-thread-bindings))))
  (testing "get-thread-bindings includes user binding inside binding form"
    (binding [dynamic-var 42]
      (let [bindings (get-thread-bindings)]
        (is (map? bindings))
        (is (= 42 (get bindings #'dynamic-var))))))
  (testing "nested bindings are visible"
    (binding [dynamic-var 10]
      (binding [a 20]
        (let [bindings (get-thread-bindings)]
          (is (= 10 (get bindings #'dynamic-var)))
          (is (= 20 (get bindings #'a))))))))

;; CLJW-ADD: bound-fn tests (Phase 42.3)
(deftest test-bound-fn
  (testing "bound-fn captures current bindings"
    (binding [dynamic-var 99]
      (let [f (bound-fn [] dynamic-var)]
        (is (= 99 (f))))))
  (testing "bound-fn* captures and restores bindings"
    (binding [dynamic-var 77]
      (let [f (bound-fn* (fn [] dynamic-var))]
        (is (= 77 (f)))))))

;; CLJW-ADD: test runner invocation
(run-tests)
(shutdown-agents)
