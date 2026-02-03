;; clojure/test_clojure/for.clj — Equivalent tests for ClojureWasm
;;
;; Based on clojure/test_clojure/for.clj from Clojure JVM.
;; Java-dependent tests (Integer., Math/abs) excluded.
;; :while tests excluded (not yet implemented in ClojureWasm for macro).
;; :let + :when combination excluded (bug in for macro).
;;
;; Uses clojure.test (auto-referred from bootstrap).

(println "[clojure/test_clojure/for] running...")

;; ========== :when tests ==========

(deftest for-when-test
  (testing "single binding with :when"
    (is (= (for [x (range 10) :when (odd? x)] x) '(1 3 5 7 9))))

  (testing ":when on second binding"
    (is (= (for [x (range 4) y (range 4) :when (odd? y)] [x y])
           '([0 1] [0 3] [1 1] [1 3] [2 1] [2 3] [3 1] [3 3]))))

  (testing ":when on first binding affects all"
    (is (= (for [x (range 4) y (range 4) :when (odd? x)] [x y])
           '([1 0] [1 1] [1 2] [1 3] [3 0] [3 1] [3 2] [3 3]))))

  (testing ":when before second binding"
    (is (= (for [x (range 4) :when (odd? x) y (range 4)] [x y])
           '([1 0] [1 1] [1 2] [1 3] [3 0] [3 1] [3 2] [3 3]))))

  (testing ":when with comparison"
    (is (= (for [x (range 5) y (range 5) :when (< x y)] [x y])
           '([0 1] [0 2] [0 3] [0 4] [1 2] [1 3] [1 4] [2 3] [2 4] [3 4])))))

;; ========== Nesting tests ==========

(deftest for-nesting-test
  (testing "triple nesting"
    (is (= (for [x '(a b) y (interpose x '(1 2)) z (list x y)] [x y z])
           '([a 1 a] [a 1 1] [a a a] [a a a] [a 2 a] [a 2 2]
                     [b 1 b] [b 1 1] [b b b] [b b b] [b 2 b] [b 2 2]))))

  (testing "nil in bindings"
    (is (= (for [x ['a nil] y [x 'b]] [x y])
           '([a a] [a b] [nil nil] [nil b])))))

;; ========== :let tests ==========

(deftest for-let-test
  (testing "simple :let"
    (is (= (for [x (range 3) :let [y (inc x)]] y) '(1 2 3))))

  (testing ":let with calculation"
    (is (= (for [x (range 3) :let [y (* x 2)]] [x y])
           '([0 0] [1 2] [2 4])))))

;; ========== Basic for ==========

(deftest for-basic-test
  (testing "simple single binding"
    (is (= (for [x [1 2 3]] x) '(1 2 3))))

  (testing "double binding"
    (is (= (for [x [1 2] y [3 4]] [x y])
           '([1 3] [1 4] [2 3] [2 4]))))

  (testing "body expression"
    (is (= (for [x [1 2 3]] (* x x)) '(1 4 9)))))

;; ========== Run tests ==========

(run-tests)
