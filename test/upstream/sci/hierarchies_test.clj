;; Upstream: sci/test/sci/hierarchies_test.cljc
;; Upstream lines: 28
;; CLJW markers: 3

(ns sci.hierarchies-test
  ;; CLJW: removed sci.test-utils dependency, direct tests
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; CLJW: use make-hierarchy for test isolation (SCI used separate eval sessions)
(deftest derive-test
  (let [h (-> (make-hierarchy)
              (derive ::foo ::bar))]
    (is (true? (isa? h ::foo ::bar))))
  (testing "fresh hierarchy has no derivation"
    (is (false? (isa? (make-hierarchy) ::foo ::bar)))))

(deftest descendants-test
  (let [h (-> (make-hierarchy)
              (derive ::foo ::bar)
              (derive ::baz ::bar))]
    (is (= #{:sci.hierarchies-test/foo :sci.hierarchies-test/baz}
           (descendants h ::bar)))))

(deftest ancestors-test
  (let [h (-> (make-hierarchy)
              (derive ::foo ::bar)
              (derive ::bar ::baz))]
    (is (= #{:sci.hierarchies-test/bar :sci.hierarchies-test/baz}
           (ancestors h ::foo)))))

(deftest parents-test
  (let [h (-> (make-hierarchy)
              (derive ::foo ::bar))]
    (is (= #{:sci.hierarchies-test/bar}
           (parents h ::foo)))))

;; CLJW: adapted from global to local hierarchy
(deftest underive-test
  (let [h (-> (make-hierarchy)
              (derive ::foo ::bar)
              (underive ::foo ::bar))]
    (is (empty? (parents h ::foo)))))

(run-tests)
