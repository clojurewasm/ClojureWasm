;; CLJW-ADD: Tests for multimethods
;; defmulti, defmethod, prefer-method, remove-method

(ns clojure.test-clojure.multimethods
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== basic multimethod ==========

(defmulti greeting :language)
(defmethod greeting :english [m] (str "Hello, " (:name m)))
(defmethod greeting :french [m] (str "Bonjour, " (:name m)))
(defmethod greeting :default [m] (str "Hi, " (:name m)))

(deftest test-basic-multimethod
  (testing "dispatch on keyword"
    (is (= "Hello, World" (greeting {:language :english :name "World"})))
    (is (= "Bonjour, World" (greeting {:language :french :name "World"}))))
  (testing "default method"
    (is (= "Hi, World" (greeting {:language :unknown :name "World"})))))

;; ========== multimethod with function dispatch ==========

(defmulti area :shape)
(defmethod area :circle [{:keys [radius]}]
  (* Math/PI radius radius))
(defmethod area :rect [{:keys [width height]}]
  (* width height))

(deftest test-fn-dispatch
  (testing "circle area"
    (is (< (Math/abs (- (* Math/PI 25) (area {:shape :circle :radius 5}))) 0.001)))
  (testing "rect area"
    (is (= 20 (area {:shape :rect :width 4 :height 5})))))

;; ========== remove-method ==========

(defmulti removable-mm identity)
(defmethod removable-mm :a [_] "a")
(defmethod removable-mm :b [_] "b")

(deftest test-remove-method
  (testing "method exists"
    (is (= "a" (removable-mm :a))))
  (testing "remove-method"
    (remove-method removable-mm :b)
    (is (thrown? Exception (removable-mm :b)))))

;; ========== methods ==========

(deftest test-methods
  (testing "methods returns dispatch map"
    (let [ms (methods greeting)]
      (is (map? ms))
      (is (contains? ms :english))
      (is (contains? ms :french)))))

;; ========== isa? hierarchy ==========

(deftest test-isa-hierarchy
  (testing "basic isa? with keywords"
    (is (isa? :a :a))
    (is (not (isa? :a :b))))
  (testing "derive and isa?"
    (derive ::child ::parent)
    (is (isa? ::child ::parent))
    (is (not (isa? ::parent ::child)))))

(run-tests)
