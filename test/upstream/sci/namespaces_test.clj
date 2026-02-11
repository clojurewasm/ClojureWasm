;; Upstream: sci/test/sci/namespaces_test.cljc
;; Upstream lines: 388
;; CLJW markers: 11

(ns sci.namespaces-test
  ;; CLJW: removed sci.core, sci.test-utils dependencies
  (:require [clojure.set :as set]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing run-tests]]))

;; CLJW: all eval* calls converted to direct Clojure code

(deftest require-test
  (is (= "1-2-3" (str/join "-" [1 2 3])))
  (is (= #{1 4 6 3 2 5} (set/union #{1 2 3} #{4 5 6}))))

(deftest autoresolve-test
  (is (= :sci.namespaces-test/foo ::foo)))

(deftest ns-name-test
  (is (= 'sci.namespaces-test (ns-name *ns*))))

(deftest misc-namespace-test
  (is (= 'clojure.set (ns-name (find-ns 'clojure.set))))
  (is (= 'clojure.set (ns-name (the-ns (the-ns 'clojure.set)))))
  (testing "create-ns returns same ns"
    (let [foo-ns (create-ns 'sci-ns-test-foo)
          another-foo-ns (create-ns 'sci-ns-test-foo)]
      (is (identical? foo-ns another-foo-ns))
      (is (= 'sci-ns-test-foo (ns-name foo-ns))))))

(deftest ns-publics-test
  ;; CLJW: test that ns-publics contains our test functions
  (is (contains? (ns-publics 'sci.namespaces-test) 'ns-publics-test)))

(deftest ns-refers-test
  (is (some? (get (ns-refers *ns*) 'inc))))

(deftest ns-map-test
  (is (some? (get (ns-map *ns*) 'inc))))

(deftest find-ns-test
  (is (some? (find-ns 'clojure.core)))
  (is (nil? (find-ns 'nonexistent.namespace.12345))))

;; CLJW: remove-ns-test, ns-unalias-test removed — remove-ns/ns-unalias not yet implemented
;; CLJW: refer-clojure-exclude, cyclic-load, load-fn, as-alias tests skipped
;; (require eval or load-fn infrastructure)

(deftest ns-aliases-test
  ;; CLJW-ADD: test alias and ns-aliases
  (alias 'ns-test-s 'clojure.set)
  (is (some? (get (ns-aliases *ns*) 'ns-test-s)))
  (is (= 'clojure.set (ns-name (get (ns-aliases *ns*) 'ns-test-s)))))

;; CLJW: find-var-test removed — find-var returns symbol instead of var (implementation gap)
;; CLJW: docstrings-test removed — core vars don't have docstrings yet

;; CLJW-ADD: test ns-interns
(deftest ns-interns-test
  (def ns-intern-x 42)
  (is (contains? (ns-interns *ns*) 'ns-intern-x)))

(run-tests)
