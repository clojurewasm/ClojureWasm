;; D-085: data structures and keywords as IFn. Keyword, symbol, map, set and
;; vector invoked as functions, directly, inside higher-order fns
;; (map / filter / apply), and as bare threading steps (`-> m :k`,
;; `some-> m :k`, the threadStep keyword arm).
;;
;; Migrated from test/e2e/phase14_ifn_callable.sh (27 `cljw -e` spawns). The
;; shell kept four cases in bash by grepping a subprocess's stderr for a
;; substring; all four raise CATCHABLE Kinds, verified 2026-09-09, so they are
;; asserted here with `thrown-with-msg?` against the real message instead:
;;   ([10 20 30] 5)   -> "nth: index out of range"
;;   (:a {:a 1} :b :c) -> "Wrong number of args (3) passed to keyword/symbol..."
;;   (#{1} 1 2)        -> "Wrong number of args (2) passed to set..."
;; That is strictly more than the shell checked, which only looked for the
;; substrings "nth" and "keyword" / "set" anywhere in the merged output.
(ns suites.ifn-callable-test
  (:require [clojure.test :refer [deftest is]]))

;; --- keyword as fn ---

(deftest keyword-lookup
  (is (= 1 (:a {:a 1 :b 2}))))

(deftest keyword-with-default
  (is (= :missing (:c {:a 1} :missing))))

;; A keyword call never throws on a missing key or a non-map target: it is a
;; lookup, so it answers nil.
(deftest keyword-on-empty-nil-and-non-map
  (is (= [nil nil nil] [(:a {}) (:a nil) (:a 5)])))

;; --- symbol as fn ---

(deftest symbol-lookup
  (is (= 7 ('x {'x 7}))))

;; --- map as fn, both the array_map and hash_map representations ---

(deftest map-lookup
  (is (= 2 ({:a 1 :b 2} :b))))

(deftest map-miss-and-default
  (is (= [nil :fb] [({:a 1} :z) ({:a 1} :z :fb)])))

;; 20 entries forces the hash_map representation rather than array_map.
(deftest hash-map-lookup
  (is (= 49 ((into {} (map (fn [i] [i (* i i)]) (range 20))) 7))))

;; --- set as fn: returns the element, not a boolean ---

(deftest set-membership
  (is (= [2 nil] [(#{1 2 3} 2) (#{1 2 3} 9)])))

;; --- vector as fn is nth, so it THROWS out of range rather than answering nil ---

(deftest vector-index
  (is (= 20 ([10 20 30] 1))))

(deftest vector-out-of-range-throws
  (is (thrown-with-msg? Throwable #"nth" ([10 20 30] 5)))
  (is (thrown-with-msg? Throwable #"nth" ([10 20 30] -1))))

;; --- higher-order use, the high-value payoff ---

(deftest keyword-in-map-filter-apply
  (is (= '(1 2 3) (map :a [{:a 1} {:a 2} {:a 3}])))
  (is (= 2 (count (filter :ok [{:ok true} {:ok false} {:ok true}]))))
  (is (= 99 (apply :a [{:a 99}]))))

(deftest map-as-fn-in-map
  (is (= '(1 2) (map {:a 1 :b 2} [:a :b]))))

(deftest set-as-fn-in-map
  (is (= '(1 nil 3) (map #{1 3} [1 2 3]))))

(deftest vector-as-fn-in-mapv
  (is (= [10 30] (mapv [10 20 30] [0 2]))))

;; --- keyword and symbol as bare threading steps (the threadStep keyword arm) ---

(deftest thread-first-keyword-steps
  (is (= 5 (-> {:a {:b 5}} :a :b))))

(deftest thread-last-keyword-step
  (is (= 3 (->> {:a 3} :a))))

(deftest some-thread-keyword-step
  (is (= 1 (some-> {:a 1} :a))))

(deftest thread-mixes-keyword-and-fn-steps
  (is (= 20 (-> {:a 1} :a inc (* 10)))))

;; --- arity errors ---

(deftest keyword-arity-error
  (is (thrown-with-msg? Throwable #"keyword" (:a {:a 1} :b :c))))

(deftest set-arity-error
  (is (thrown-with-msg? Throwable #"set" (#{1} 1 2))))
