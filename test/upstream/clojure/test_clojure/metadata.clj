;; CLJW-ADD: Tests for metadata operations
;; meta, with-meta, vary-meta, alter-meta!

(ns clojure.test-clojure.metadata
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== meta / with-meta ==========

(deftest test-meta-basic
  (testing "with-meta on map"
    (let [m (with-meta {:a 1} {:doc "test"})]
      (is (= {:doc "test"} (meta m)))
      (is (= {:a 1} m))))
  (testing "with-meta on vector"
    (let [v (with-meta [1 2 3] {:tag :vec})]
      (is (= {:tag :vec} (meta v)))
      (is (= [1 2 3] v))))
  (testing "with-meta on list"
    (let [l (with-meta '(1 2 3) {:type :list})]
      (is (= {:type :list} (meta l)))))
  (testing "with-meta on set"
    (let [s (with-meta #{1 2 3} {:unique true})]
      (is (= {:unique true} (meta s)))))
  (testing "nil meta"
    (is (nil? (meta [1 2 3]))))
  (testing "with-meta replaces"
    (let [v (with-meta [1] {:a 1})
          v2 (with-meta v {:b 2})]
      (is (= {:b 2} (meta v2))))))

;; ========== vary-meta ==========

(deftest test-vary-meta
  (testing "vary-meta adds"
    (let [v (with-meta [] {:a 1})
          v2 (vary-meta v assoc :b 2)]
      (is (= {:a 1 :b 2} (meta v2)))))
  (testing "vary-meta dissoc"
    (let [v (with-meta [] {:a 1 :b 2})
          v2 (vary-meta v dissoc :b)]
      (is (= {:a 1} (meta v2))))))

;; ========== def metadata ==========

(deftest test-def-metadata
  (testing "def with ^:dynamic"
    (is (true? (:dynamic (meta #'*ns*))))))

;; ========== fn metadata ==========

(deftest test-fn-metadata
  (testing "defn adds metadata"
    (defn ^{:tag String} my-fn "doc" [x] x)
    (is (= "doc" (:doc (meta #'my-fn))))))

;; ========== alter-meta! ==========

(deftest test-alter-meta
  (testing "alter-meta! on var"
    (def test-var 42)
    (alter-meta! #'test-var assoc :custom true)
    (is (true? (:custom (meta #'test-var)))))
  (testing "reset-meta! on var"
    (def test-var2 42)
    (reset-meta! #'test-var2 {:replaced true})
    (is (true? (:replaced (meta #'test-var2))))))

(run-tests)
