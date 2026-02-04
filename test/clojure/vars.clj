;; Ported from clojure/test_clojure/vars.clj
;; SKIP: test-binding (needs binding special form — F85)
;; SKIP: test-with-local-vars (with-local-vars not implemented)
;; SKIP: test-with-precision (BigDecimal not supported)
;; SKIP: test-settable-math-context (JVM-specific)
;; SKIP: test-with-redefs (needs Thread, promise — JVM)
;; SKIP: test-vars-apply-lazily (needs future, infinite range — JVM)
;; SKIP: bound? (takes symbol not var_ref, needs fix — F86)
;; SKIP: #'var inside deftest body (var quote resolves at analyze time — F87)
;; SKIP: ^:dynamic def (metadata reader on def not supported — F88)
;; NOTE: defn docstring doesn't set var metadata (simplified defn macro)

(ns clojure.test-clojure.vars
  (:use clojure.test))

;; === def basics ===

(deftest test-def
  (testing "def creates a var with a value"
    (def test-val 42)
    (is (= 42 test-val)))
  (testing "def with nil value"
    (def test-nil nil)
    (is (nil? test-nil)))
  (testing "def with string"
    (def test-str "hello")
    (is (= "hello" test-str)))
  (testing "def with collection"
    (def test-vec [1 2 3])
    (is (= [1 2 3] test-vec))))

;; === defonce ===

(deftest test-defonce
  (defonce once-val 10)
  (is (= 10 once-val))
  (defonce once-val 20)
  (is (= 10 once-val)))

;; === declare ===

(deftest test-declare
  (declare later-var)
  (def later-var 99)
  (is (= 99 later-var)))

;; === var? ===

(def var-test-val 1)

(deftest test-var-pred
  (is (= true (var? #'var-test-val)))
  (is (= false (var? 42)))
  (is (= false (var? "hello")))
  (is (= false (var? :keyword)))
  (is (= false (var? [1 2 3]))))

;; === defn ===

(deftest test-defn
  (testing "defn creates a function"
    (defn add-nums [a b] (+ a b))
    (is (= 5 (add-nums 2 3))))
  (testing "defn with multiple arities"
    (defn greet
      ([] "hello")
      ([name] (str "hello " name)))
    (is (= "hello" (greet)))
    (is (= "hello world" (greet "world"))))
  (testing "defn with rest args"
    (defn sum-all [& nums]
      (apply + nums))
    (is (= 10 (sum-all 1 2 3 4)))))

;; === defn- ===

(deftest test-defn-private
  (defn- private-fn [x] (* x 2))
  (is (= 10 (private-fn 5))))

;; === Var deref ===

(def deref-test-val 42)

(deftest test-var-deref
  (is (= 42 (deref #'deref-test-val)))
  (is (= 42 @#'deref-test-val)))

;; === Var as IFn ===

(defn var-fn-test [x] (* x 3))

(deftest test-var-invoke
  (is (= 9 (#'var-fn-test 3))))

;; === def overwrites ===

(deftest test-def-overwrite
  (def ow-val 1)
  (is (= 1 ow-val))
  (def ow-val 2)
  (is (= 2 ow-val)))

;; Run tests
(run-tests)
