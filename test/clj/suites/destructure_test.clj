;; D-076 destructuring: sequential, associative, fn-param, loop and kwargs
;; patterns, lowered at the macro layer (expandLet, the JVM
;; clojure.core/destructure shape).
;;
;; Migrated from test/e2e/phase14_destructure.sh (31 `cljw -e` spawns). Nothing
;; here touched the process: every case was "evaluate an expression, compare
;; the PRINTED form". Asserting the VALUE instead is strictly stronger, since
;; the shell could not tell the list `(3 4)` from a string that prints like one.
;;
;; `test/e2e/phase14_destructure_fn.sh` is a DIFFERENT file (clojure.core's
;; `destructure` fn as a callable, D-396) and is untouched by this migration.
(ns suites.destructure-test
  (:require [clojure.test :refer [deftest is]]))

;; --- cycle 1: sequential vector patterns ---

(deftest sequential-basic
  (is (= 3 (let [[a b] [1 2]] (+ a b)))))

(deftest sequential-rest
  (is (= '(3 4) (let [[a b & r] [1 2 3 4]] r))))

(deftest sequential-as
  (is (= [1 2] (let [[a b :as all] [1 2]] all))))

(deftest sequential-nested
  (is (= 6 (let [[[a b] c] [[1 2] 3]] (+ a b c)))))

(deftest sequential-missing-is-nil
  (is (nil? (let [[a b] [1]] b))))

;; A later binding sees the names the earlier pattern introduced.
(deftest sequential-dependency
  (is (= 3 (let [[a b] [1 2] c (+ a b)] c))))

(deftest sequential-rest-only
  (is (= '(1 2 3) (let [[& r] [1 2 3]] r))))

;; The all-plain-symbols fast path must stay unchanged by the destructuring
;; lowering.
(deftest plain-symbol-fast-path
  (is (= 3 (let [x 1 y 2] (+ x y)))))

;; --- cycle 2: associative {:keys/:syms/:or/:as/bare} ---

(deftest map-keys
  (is (= 3 (let [{:keys [a b]} {:a 1 :b 2}] (+ a b)))))

(deftest map-or-default
  (is (= 11 (let [{:keys [a b] :or {b 10}} {:a 1}] (+ a b)))))

(deftest map-as
  (is (= [1 2] (let [{:keys [a] :as m} {:a 1 :b 2}] [a (count m)]))))

(deftest map-bare-bindings
  (is (= 3 (let [{a :alpha b :beta} {:alpha 1 :beta 2}] (+ a b)))))

(deftest map-syms
  (is (= 5 (let [{:syms [q]} {'q 5}] q))))

(deftest map-missing-is-nil
  (is (nil? (let [{:keys [z]} {:a 1}] z))))

(deftest map-nested-in-sequential
  (is (= 3 (let [[{:keys [a]} c] [{:a 1} 2]] (+ a c)))))

(deftest sequential-nested-in-map
  (is (= 3 (let [{[a b] :pair} {:pair [1 2]}] (+ a b)))))

;; `:strs` (string keys) is functionally blocked by the map string-key lookup
;; gap (D-151: `(get {"x" 5} "x")` returns nil). Its lowering is correct and
;; forward-compatible, so it is intentionally not asserted.

;; --- cycle 3: fn / defn param destructuring (gensym param + body let) ---

(deftest fn-sequential-param
  (is (= 3 ((fn [[a b]] (+ a b)) [1 2]))))

(deftest fn-map-param
  (is (= 3 ((fn [{:keys [a b]}] (+ a b)) {:a 1 :b 2}))))

(deftest fn-rest-pattern
  (is (= 6 ((fn [a & [b c]] (+ a b c)) 1 2 3))))

(deftest fn-plain-params-unregressed
  (is (= 7 ((fn [a b] (+ a b)) 3 4))))

(defn- f-map-param [{:keys [x]}] x)

(deftest defn-map-param
  (is (= 5 (f-map-param {:x 5}))))

(defn- g-multi
  ([[a]] a)
  ([[a b] c] (+ a b c)))

(deftest defn-multi-arity-destructure
  (is (= [9 6] [(g-multi [9]) (g-multi [1 2] 3)])))

;; --- cycle 4: the loop macro (loop* rename) + loop destructuring ---

(deftest loop-plain
  (is (= 3 (loop [x 0] (if (< x 3) (recur (inc x)) x)))))

(deftest loop-sequential
  (is (= 5 (loop [[a b] [1 2]] (if (< a 3) (recur [(inc a) b]) (+ a b))))))

(deftest loop-rest
  (is (= 6 (loop [sum 0 [x & xs] [1 2 3]] (if x (recur (+ sum x) xs) sum)))))

(deftest loop-map
  (is (= :done (loop [{:keys [n]} {:n 5}] (if (> n 0) (recur {:n (dec n)}) :done)))))

;; `loop*` itself still works: the `loop` macro is a rename over it.
(deftest loop-star-primitive
  (is (= 2 (loop* [x 0] (if (< x 2) (recur (inc x)) x)))))

;; --- cycle 5: keyword-args destructuring (& {:keys [...]}) ---
;; A seq operand in a map-destructure is coerced to a map, as clj does with
;; (apply hash-map ...).

(deftest kwargs-keys
  (is (= [1 2] ((fn [& {:keys [x y]}] [x y]) :x 1 :y 2))))

(deftest kwargs-with-leading-param
  (is (= [1 2] ((fn [a & {:keys [x]}] [a x]) 1 :x 2))))

(deftest kwargs-or-default
  (is (= 9 ((fn [& {:keys [x] :or {x 9}}] x)))))

(deftest map-destructure-of-seq
  (is (= 1 (let [{:keys [x]} '(:x 1)] x))))
