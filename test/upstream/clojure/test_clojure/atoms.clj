;; clojure/test_clojure/atoms.clj — Equivalent tests for ClojureWasm
;;
;; Based on clojure/test_clojure/atoms.clj from Clojure JVM.
;; Java-dependent tests excluded (Supplier interfaces).
;; swap-vals!/reset-vals! not yet implemented (F38/F39).
;;
;; Uses clojure.test (auto-referred from bootstrap).

(println "[clojure/test_clojure/atoms] running...")

;; ========== atom creation ==========

(deftest test-atom-creation
  (testing "atom with initial value"
    (is (= 0 @(atom 0)))
    (is (= "hello" @(atom "hello")))
    (is (= :keyword @(atom :keyword)))
    (is (= nil @(atom nil)))))

(deftest test-atom-with-collections
  (testing "atom with collection values"
    (is (= [] @(atom [])))
    (is (= [1 2 3] @(atom [1 2 3])))
    (is (= {} @(atom {})))
    (is (= {:a 1 :b 2} @(atom {:a 1 :b 2})))
    (is (= #{} @(atom #{})))
    (is (= #{1 2 3} @(atom #{1 2 3})))))

;; ========== deref ==========

(deftest test-deref
  (testing "deref returns current atom value"
    (let [a (atom 42)]
      (is (= 42 (deref a)))
      (is (= 42 @a)))))

;; ========== swap! ==========

(deftest test-swap!-basic
  (testing "swap! with unary function"
    (let [a (atom 0)]
      (swap! a inc)
      (is (= 1 @a))
      (swap! a inc)
      (is (= 2 @a)))))

(deftest test-swap!-returns-new-value
  (testing "swap! returns the new value"
    (let [a (atom 0)]
      (is (= 1 (swap! a inc)))
      (is (= 2 (swap! a inc))))))

(deftest test-swap!-with-args
  (testing "swap! with additional arguments"
    (let [a (atom 0)]
      (is (= 5 (swap! a + 5)))
      (is (= 8 (swap! a + 1 2)))
      (is (= 14 (swap! a + 1 2 3))))))

(deftest test-swap!-with-collections
  (testing "swap! on atom holding vector"
    (let [a (atom [])]
      (swap! a conj 1)
      (is (= [1] @a))
      (swap! a conj 2)
      (is (= [1 2] @a))))
  (testing "swap! on atom holding map"
    (let [a (atom {})]
      (swap! a assoc :a 1)
      (is (= {:a 1} @a))
      (swap! a assoc :b 2)
      (is (= {:a 1 :b 2} @a)))))

;; ========== reset! ==========

(deftest test-reset!-basic
  (testing "reset! sets new value"
    (let [a (atom 0)]
      (reset! a 100)
      (is (= 100 @a))
      (reset! a "hello")
      (is (= "hello" @a)))))

(deftest test-reset!-returns-new-value
  (testing "reset! returns the new value"
    (let [a (atom 0)]
      (is (= 42 (reset! a 42)))
      (is (= :done (reset! a :done))))))

;; ========== compare-and-set! ==========

(deftest test-compare-and-set!-success
  (testing "compare-and-set! succeeds when old value matches"
    (let [a (atom 0)]
      (is (true? (compare-and-set! a 0 1)))
      (is (= 1 @a)))))

(deftest test-compare-and-set!-failure
  (testing "compare-and-set! fails when old value doesn't match"
    (let [a (atom 0)]
      (is (false? (compare-and-set! a 99 1)))
      (is (= 0 @a)))))

(deftest test-compare-and-set!-with-nil
  (testing "compare-and-set! with nil values"
    (let [a (atom nil)]
      (is (true? (compare-and-set! a nil :value)))
      (is (= :value @a)))
    (let [a (atom :value)]
      (is (true? (compare-and-set! a :value nil)))
      (is (= nil @a)))))

;; ========== atom with nested operations ==========

(deftest test-atom-nested-operations
  (testing "nested swap! calls"
    (let [counter (atom 0)
          results (atom [])]
      (dotimes [_ 5]
        (swap! results conj (swap! counter inc)))
      (is (= 5 @counter))
      (is (= [1 2 3 4 5] @results)))))

(deftest test-atom-update-with-current-value
  (testing "swap! function can read current value"
    (let [a (atom {:count 0})]
      (swap! a (fn [m] (assoc m :count (inc (:count m)))))
      (is (= {:count 1} @a))
      (swap! a (fn [m] (assoc m :count (inc (:count m)))))
      (is (= {:count 2} @a)))))

;; ========== swap-vals! / reset-vals! ==========
;; Not yet implemented in ClojureWasm (F38, F39)

;; (deftest swap-vals-returns-old-value
;;   (let [a (atom 0)]
;;     (is (= [0 1] (swap-vals! a inc)))
;;     (is (= [1 2] (swap-vals! a inc)))
;;     (is (= 2 @a))))

;; (deftest deref-swap-arities
;;   (let [a (atom 0)]
;;     (is (= [0 1] (swap-vals! a + 1)))
;;     (is (= [1 3] (swap-vals! a + 1 1)))
;;     (is (= [3 6] (swap-vals! a + 1 1 1)))
;;     (is (= [6 10] (swap-vals! a + 1 1 1 1)))
;;     (is (= 10 @a))))

;; (deftest deref-reset-returns-old-value
;;   (let [a (atom 0)]
;;     (is (= [0 :b] (reset-vals! a :b)))
;;     (is (= [:b 45] (reset-vals! a 45)))
;;     (is (= 45 @a))))

;; ========== Run tests ==========

(run-tests)
