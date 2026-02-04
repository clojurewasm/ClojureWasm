;; Ported from clojure/test_clojure/macros.clj
;; Tests for threading macros: ->, ->>, some->, some->>, cond->, cond->>, as->
;;
;; Excluded:
;;   - ->test, ->>test: user-defined macro `c` — VM doesn't expand user macros
;;   - ->metadata-test, ->>metadata-test: with-meta on symbols not supported
;;   - threading-loop-recur: VM compiler stack_depth underflow with recur in when-not
;;
;; Uses clojure.test (auto-referred via ns :use).

(ns test.macros
  (:use clojure.test))

(println "[test/macros] running...")

(def constantly-nil (constantly nil))

(deftest some->test
  (is (nil? (some-> nil)))
  (is (= 0 (some-> 0)))
  (is (= -1 (some-> 1 (- 2))))
  (is (nil? (some-> 1 constantly-nil (- 2)))))

(deftest some->>test
  (is (nil? (some->> nil)))
  (is (= 0 (some->> 0)))
  (is (= 1 (some->> 1 (- 2))))
  (is (nil? (some->> 1 constantly-nil (- 2)))))

(deftest cond->test
  (is (= 0 (cond-> 0)))
  (is (= -1 (cond-> 0 true inc true (- 2))))
  (is (= 0 (cond-> 0 false inc)))
  (is (= -1 (cond-> 1 true (- 2) false inc))))

(deftest cond->>test
  (is (= 0 (cond->> 0)))
  (is (= 1 (cond->> 0 true inc true (- 2))))
  (is (= 0 (cond->> 0 false inc)))
  (is (= 1 (cond->> 1 true (- 2) false inc))))

(deftest as->test
  (is (= 0 (as-> 0 x)))
  (is (= 1 (as-> 0 x (inc x))))
  (is (= 2 (as-> [0 1] x
             (map inc x)
             (reverse x)
             (first x)))))

;; Excluded: threading-loop-recur — VM compiler stack_depth underflow
;; with recur inside when-not/some->/cond-> (F76)
;; (deftest threading-loop-recur ...)

(run-tests)
