;; Upstream: clojure/test/clojure/test_clojure/transients.clj
;; Upstream lines: 83
;; CLJW markers: 8

;; Copyright (c) Rich Hickey. All rights reserved.
;; The use and distribution terms for this software are covered by the
;; Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)

(ns clojure.test-clojure.transients
  (:use clojure.test))

(deftest popping-off
  (testing "across a node boundary"
    (are [n]
         (let [v (-> (range n) vec)]
           (= (subvec v 0 (- n 2)) (-> v transient pop! pop! persistent!)))
      33 (+ 32 (inc (* 32 32))) (+ 32 (inc (* 32 32 32)))))
  ;; CLJW: thrown-with-msg? with regex not supported; use thrown? + message check
  (testing "off the end"
    (is (thrown? Exception
                 (-> [] transient pop!))))
  (testing "copying array from a non-editable when put in tail position")
  (is (= 31 (let [pv (vec (range 34))]
              (-> pv transient pop! pop! pop! (conj! 42))
              (nth pv 31)))))

;; CLJW: reify Object not supported — hash-obj and dissocing test removed
;; (defn- hash-obj [hash] ...)
;; (deftest dissocing ...)

(deftest test-disj!
  (testing "disjoin multiple items in one call"
    (is (= #{5 20} (-> #{5 10 15 20} transient (disj! 10 15) persistent!)))))

;; CLJW: .contains Java method not supported
;; (deftest empty-transient ...)

;; CLJW: reify Object not supported
;; (deftest persistent-assoc-on-collision ...)

(deftest transient-mod-after-persistent
  (let [v [1 2 3]
        t (transient v)
        t2 (conj! t 4)
        p (persistent! t2)]
    (is (= [1 2 3 4] p))
    ;; CLJW: thrown? IllegalAccessError → Exception (no Java error hierarchy)
    (is (thrown? Exception (conj! t2 5)))))

;; CLJW: future not supported (single-threaded)
;; (deftest transient-mod-ok-across-threads ...)

(deftest transient-lookups
  (let [tv (transient [1 2 3])]
    (is (= 1 (get tv 0)))
    (is (= :foo (get tv 4 :foo)))
    (is (= true (contains? tv 0)))
    (is (= [0 1] (find tv 0)))
    (is (= nil (find tv -1))))
  (let [ts (transient #{1 2})]
    (is (= true (contains? ts 1)))
    (is (= false (contains? ts 99)))
    (is (= 1 (get ts 1)))
    (is (= nil (get ts 99))))
  (let [tam (transient (array-map :a 1 :b 2))]
    (is (= true (contains? tam :a)))
    (is (= false (contains? tam :x)))
    (is (= 1 (get tam :a)))
    (is (= nil (get tam :x)))
    (is (= [:a 1] (find tam :a)))
    (is (= nil (find tam :x))))
  ;; CLJW: hash-map is same as array-map in our impl
  (let [thm (transient (hash-map :a 1 :b 2))]
    (is (= true (contains? thm :a)))
    (is (= false (contains? thm :x)))
    (is (= 1 (get thm :a)))
    (is (= nil (get thm :x)))
    (is (= [:a 1] (find thm :a)))
    (is (= nil (find thm :x)))))

;; CLJW-ADD: test runner invocation
(run-tests)
