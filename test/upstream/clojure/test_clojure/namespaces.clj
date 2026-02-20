;; CLJW-ADD: Tests for namespace operations
;; ns, require, use, alias, refer, ns-map, ns-publics, etc.

(ns clojure.test-clojure.namespaces
  (:require [clojure.test :refer [deftest is testing run-tests]]
            [clojure.string :as str]))

;; ========== basic ns queries ==========

(deftest test-ns-queries
  (testing "find-ns"
    (is (some? (find-ns 'clojure.core)))
    (is (nil? (find-ns 'nonexistent.ns.12345))))
  (testing "the-ns"
    (is (some? (the-ns 'clojure.core))))
  (testing "ns-name"
    (is (= 'clojure.core (ns-name (the-ns 'clojure.core))))))

;; ========== ns-publics / ns-map ==========

(deftest test-ns-publics
  (testing "ns-publics returns map"
    (let [pubs (ns-publics 'clojure.core)]
      (is (map? pubs))
      (is (contains? pubs 'map))
      (is (contains? pubs 'filter))))
  (testing "ns-map contains more than publics"
    (let [m (ns-map 'clojure.core)]
      (is (map? m))
      (is (> (count m) 0)))))

;; ========== aliases ==========

(deftest test-ns-aliases
  (testing "alias is available"
    (is (= (the-ns 'clojure.string)
           (get (ns-aliases *ns*) 'str)))))

;; ========== resolve ==========

(deftest test-resolve
  (testing "resolve core var"
    (is (some? (resolve 'map)))
    (is (some? (resolve '+))))
  (testing "resolve nonexistent"
    (is (nil? (resolve 'nonexistent-symbol-xyz)))))

;; ========== all-ns ==========

(deftest test-all-ns
  (testing "all-ns returns namespaces"
    (let [nss (all-ns)]
      (is (seq nss))
      (is (some #(= 'clojure.core (ns-name %)) nss)))))

;; ========== create-ns / remove-ns ==========

(deftest test-create-remove-ns
  (testing "create-ns"
    (create-ns 'test.temp.ns)
    (is (some? (find-ns 'test.temp.ns)))
    (remove-ns 'test.temp.ns)
    (is (nil? (find-ns 'test.temp.ns)))))

(run-tests)
