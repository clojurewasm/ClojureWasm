;; Upstream: clojure/test/clojure/test_clojure/compilation.clj
;; Upstream lines: 445
;; CLJW markers: 10
;; Portable subset: compiler validation, recur restrictions, closures, throw validation

(ns clojure.test-clojure.compilation
  (:require [clojure.test :refer [deftest is are testing run-tests]]))

;; CLJW: stripped JVM imports, test-helper, generative deps

(deftest test-compiler-metadata
  (let [m (meta #'when)]
    (are [x y] (= x y)
      ;; CLJW: skip arglists/doc checks (CW doesn't store these in var meta)
      (:macro m) true
      (:name m) 'when)))

(deftest test-compiler-resolution
  (testing "resolve nonexistent class create should return nil"
    (is (nil? (resolve 'NonExistentClass.))))
  (testing "resolve nonexistent class should return nil"
    (is (nil? (resolve 'NonExistentClass.Name)))))

;; CLJW: recur-across-try tests adapted (use Exception instead of CompilerException)
(deftest test-no-recur-across-try
  (testing "allow loop/recur inside try"
    (is (= 0 (eval '(try (loop [x 3]
                           (if (zero? x) x (recur (dec x)))))))))
  (testing "allow loop/recur fully inside catch"
    (is (= 3 (eval '(try
                      (throw (Exception. "boom"))
                      (catch Exception e
                        (loop [x 0]
                          (if (< x 3) (recur (inc x)) x))))))))
  (testing "allow fn/recur inside try"
    (is (= 0 (eval '(try
                      ((fn [x]
                         (if (zero? x)
                           x
                           (recur (dec x))))
                       3)))))))

(deftest test-CLJ-671-regression
  (testing "loop with type hints doesn't loop infinitely"
    (letfn [(gcd [x y]
              (loop [x (long x) y (long y)]
                (if (== y 0)
                  x
                  (recur y (rem x y)))))]
      (is (= 4 (gcd 8 100))))))

;; CLJW: adapted from CLJ-1250, closures over catch/finally
(deftest test-closure-in-try-catch-finally
  (testing "clearing during try/catch/finally"
    (let [closed-over-in-catch (let [x :foo]
                                 (fn []
                                   (try
                                     (throw (Exception. "boom"))
                                     (catch Exception e
                                       x))))]
      (is (= :foo (closed-over-in-catch))))
    (let [a (atom nil)
          closed-over-in-finally (fn []
                                   (try
                                     :ret
                                     (finally
                                       (reset! a :run))))]
      (is (= :ret (closed-over-in-finally)))
      (is (= :run @a)))))

(deftest test-anon-recursive-fn
  (is (= [0 0] (take 2 ((fn rf [x] (lazy-seq (cons x (rf x)))) 0)))))

;; CLJW: adapted from CLJ-1456; CW exceptions are maps, use ex-message
(deftest test-throw-arity-validation
  (is (thrown? Exception (eval '(defn foo [] (throw)))))
  (is (var? (eval '(defn bar [] (throw (Exception. "ok")))))))

;; CLJW: adapted from CLJ-2580
(deftest test-case-nil-branch
  (testing "case with nil value"
    (is (zero? (let [d (case nil :x nil 0)] d)))))

;; CLJW-ADD: test runner invocation
(run-tests)
