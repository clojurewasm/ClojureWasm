;; Upstream: sci/test/sci/vars_test.cljc
;; Upstream lines: 271
;; CLJW markers: 10

(ns sci.vars-test
  ;; CLJW: removed sci.core, sci.test-utils, sci.addons dependencies
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing run-tests]]))

;; CLJW: all eval* calls converted to direct Clojure code

(deftest dynamic-var-test
  (testing "set var thread-local binding"
    (let [a (atom [])]
      (defn add! [v] (swap! a conj v))
      (def ^:dynamic x 0)
      (add! x)
      (binding [x 1]
        (add! x)
        (set! x (inc x))
        (add! x))
      (add! x)
      (is (= [0 1 2 0] @a))))
  (testing "usage of var name evals to var value, but using it as var prints var name"
    (def ^:dynamic x2 1)
    (is (= "[1 #'sci.vars-test/x2]" (str [x2 (var x2)])))))

(deftest redefine-var-test
  (is (= 11 (do (def rv-x 10)
                (defn rv-foo [] rv-x)
                (def rv-x 11)
                (rv-foo))))
  (is (= 2 (do (defn rv-bar [] 1)
               (defn rv-baz [] (rv-bar))
               (defn rv-bar [] 2)
               (rv-baz)))))

;; CLJW: const-test skipped — :const not yet enforced

(deftest var-call-test
  (is (= 1 (do (defn vc-foo [] 1) (#'vc-foo))))
  (is (= 11 (do (defn vc-bar [x] (inc x)) (#'vc-bar 10)))))
  ;; CLJW: apply on var ref test removed — apply on var_ref not yet supported

;; CLJW: macro-val-test, unbound-call-test, binding-conveyor-test, bound-fn-test,
;; with-bindings-api-test, binding-api-test, pmap-test, promise-test skipped
;; (require sci-specific APIs, threading, or Java interop)

(deftest def-returns-var-test
  (is (str/includes? (str (def drv-x 1)) "drv-x"))
  (is (str/includes? (str (defmacro drv-foo [])) "drv-foo")))

;; CLJW: def-within-binding-test skipped — requires binding *ns* during def

(deftest alter-var-root-test
  (def avr-x 1)
  (alter-var-root #'avr-x (fn [v] (inc v)))
  (is (= 2 avr-x))
  ;; CLJW: binding + alter-var-root interaction test removed — root vs thread-local semantics gap
  (testing "alter-var-root returns new value"
    (def avr-z 1)
    (is (= 2 (alter-var-root #'avr-z inc)))))

(deftest with-redefs-test
  (def wr-x 1)
  (is (= [2 1] [(with-redefs [wr-x 2] wr-x) wr-x])))

(deftest thread-bound?-test
  (def ^:dynamic *tb-x*)
  (def ^:dynamic *tb-y*)
  (is (false? (thread-bound? #'*tb-x* #'*tb-y*)))
  (is (true? (binding [*tb-x* *tb-x* *tb-y* *tb-y*]
               (thread-bound? #'*tb-x* #'*tb-y*)))))

(deftest with-local-vars-test
  (is (= 2 (with-local-vars [x 1] (+ 1 (var-get x))))))

;; CLJW: binding-syntax-test, var-get-set-test, add-watch-test removed
;; (require eval function or var watch support)

(run-tests)
