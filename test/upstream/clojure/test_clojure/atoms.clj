;; CLJW-ADD: Tests for atoms and refs
;; atom, swap!, reset!, compare-and-set!, add-watch, remove-watch

(ns clojure.test-clojure.atoms
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== basic atom ==========

(deftest test-atom-basic
  (testing "create and deref"
    (let [a (atom 42)]
      (is (= 42 @a))
      (is (= 42 (deref a)))))
  ;; CLJW: atom doesn't support :meta kwarg; use with-meta after creation
  (testing "atom with metadata"
    (let [a (atom 1)]
      (reset-meta! a {:tag :int})
      (is (= {:tag :int} (meta a))))))

;; ========== swap! ==========

(deftest test-swap
  (testing "basic swap!"
    (let [a (atom 0)]
      (swap! a inc)
      (is (= 1 @a))))
  (testing "swap! with args"
    (let [a (atom 0)]
      (swap! a + 5)
      (is (= 5 @a))))
  (testing "swap! returns new value"
    (let [a (atom 0)]
      (is (= 1 (swap! a inc)))))
  (testing "swap! with multi-arg fn"
    (let [a (atom [1])]
      (swap! a conj 2 3)
      (is (= [1 2 3] @a)))))

;; ========== reset! ==========

(deftest test-reset
  (testing "basic reset!"
    (let [a (atom 42)]
      (reset! a 99)
      (is (= 99 @a))))
  (testing "reset! returns new value"
    (let [a (atom 0)]
      (is (= 99 (reset! a 99))))))

;; ========== compare-and-set! ==========

(deftest test-compare-and-set
  (testing "successful CAS"
    (let [a (atom 1)]
      (is (true? (compare-and-set! a 1 2)))
      (is (= 2 @a))))
  (testing "failed CAS"
    (let [a (atom 1)]
      (is (false? (compare-and-set! a 999 2)))
      (is (= 1 @a)))))

;; ========== watches ==========

(deftest test-watches
  (testing "add-watch"
    (let [a (atom 0)
          log (atom [])]
      (add-watch a :logger
                 (fn [key ref old new]
                   (swap! log conj [old new])))
      (swap! a inc)
      (swap! a inc)
      (is (= [[0 1] [1 2]] @log))))
  (testing "remove-watch"
    (let [a (atom 0)
          log (atom [])]
      (add-watch a :logger
                 (fn [key ref old new]
                   (swap! log conj new)))
      (swap! a inc)
      (remove-watch a :logger)
      (swap! a inc)
      (is (= [1] @log)))))

;; ========== swap-vals! / reset-vals! ==========

(deftest test-swap-vals-reset-vals
  (testing "swap-vals! returns [old new]"
    (let [a (atom 1)]
      (is (= [1 2] (swap-vals! a inc)))))
  (testing "reset-vals! returns [old new]"
    (let [a (atom 1)]
      (is (= [1 99] (reset-vals! a 99))))))

(run-tests)
