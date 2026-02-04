;; Ported from clojure/test_clojure/other_functions.clj
;; Tests for identity, fnil, comp, complement, constantly, juxt, partial,
;; every-pred, some-fn, max/min-key, update, update-vals, update-keys
;;
;; SKIP: test-regex-matcher (regex not implemented)
;; SKIP: test-identity char literals (\c), BigDecimal (0M), Ratio (2/3)
;; SKIP: test-update-vals/keys with-meta/meta (no metadata support)
;; SKIP: test-update-vals/keys with hash-map/array-map/sorted-map (not distinct types)
;; SKIP: every-pred/some-fn truthiness sub-tests (depends on range/for/repeat/apply combo)

(ns test.other-functions
  (:use clojure.test))

(deftest test-identity
  (are [x] (= (identity x) x)
    nil
    false true
    0 42
    0.0 3.14
    "" "abc"
    'sym
    :kw
    [] [1 2]
    {} {:a 1 :b 2}
    #{} #{1 2})

  ;; evaluation
  (are [x y] (= (identity x) y)
    (+ 1 2) 3
    (> 5 0) true))

(deftest test-name
  (are [x y] (= x (name y))
    "foo" :foo
    "bar" 'bar
    "quux" "quux"))

(deftest test-fnil
  (let [f1 (fnil vector :a)
        f2 (fnil vector :a :b)
        f3 (fnil vector :a :b :c)]
    (are [result input] (= result [(apply f1 input) (apply f2 input) (apply f3 input)])
      [[1 2 3 4] [1 2 3 4] [1 2 3 4]]  [1 2 3 4]
      [[:a 2 3 4] [:a 2 3 4] [:a 2 3 4]] [nil 2 3 4]
      [[:a nil 3 4] [:a :b 3 4] [:a :b 3 4]] [nil nil 3 4]
      [[:a nil nil 4] [:a :b nil 4] [:a :b :c 4]] [nil nil nil 4]
      [[:a nil nil nil] [:a :b nil nil] [:a :b :c nil]] [nil nil nil nil]))
  (are [x y] (= x y)
    ((fnil + 0) nil 42) 42
    ((fnil conj []) nil 42) [42]))
  ;; SKIP: update-in + fnil tests (update-in with fnil + inc/conj combo)

(deftest test-comp
  (let [c0 (comp)]
    (are [x] (= (identity x) (c0 x))
      nil
      42
      [1 2 3]
      #{}
      :foo)
    (are [x y] (= (identity x) (c0 y))
      (+ 1 2 3) 6
      (keyword "foo") :foo)))

(deftest test-complement
  (let [not-contains? (complement contains?)]
    (is (= true (not-contains? [2 3 4] 5)))
    (is (= false (not-contains? [2 3 4] 2))))
  (let [first-elem-not-1? (complement (fn [x] (= 1 (first x))))]
    (is (= true (first-elem-not-1? [2 3])))
    (is (= false (first-elem-not-1? [1 2])))))

(deftest test-constantly
  (let [c0 (constantly 10)]
    (are [x] (= 10 (c0 x))
      nil
      42
      "foo")))

(deftest test-juxt
  ;; juxt for colls
  (let [m0 {:a 1 :b 2}
        a0 [1 2]]
    (is (= [1 2] ((juxt :a :b) m0)))
    (is (= [2 1] ((juxt fnext first) a0))))
  ;; juxt for fns
  (let [a1 (fn [a] (+ 2 a))
        b1 (fn [b] (* 2 b))]
    (is (= [5 6] ((juxt a1 b1) 3)))))

(deftest test-partial
  (let [p0 (partial inc)
        p1 (partial + 20)
        p2 (partial conj [1 2])]
    (is (= 41 (p0 40)))
    (is (= 40 (p1 20)))
    (is (= [1 2 3] (p2 3)))))

(deftest test-every-pred
  ;; 1 pred
  (is (= true  ((every-pred even?))))
  (is (= true  ((every-pred even?) 2)))
  (is (= true  ((every-pred even?) 2 4)))
  (is (= true  ((every-pred even?) 2 4 6)))
  (is (= false ((every-pred odd?) 2)))
  (is (= false ((every-pred odd?) 2 4)))
  ;; 2 preds
  (is (= true  ((every-pred even? number?))))
  (is (= true  ((every-pred even? number?) 2)))
  (is (= true  ((every-pred even? number?) 2 4)))
  (is (= false ((every-pred number? odd?) 2)))
  (is (= false ((every-pred number? odd?) 2 4)))
  ;; 3 preds
  (is (= true  ((every-pred even? number? #(> % 0)))))
  (is (= true  ((every-pred even? number? #(> % 0)) 2)))
  (is (= true  ((every-pred even? number? #(> % 0)) 2 4)))
  (is (= false ((every-pred number? odd? #(> % 0)) 2)))
  (is (= false ((every-pred number? odd? #(> % 0)) 2 4))))

(deftest test-some-fn
  ;; 1 pred
  (is (not ((some-fn even?))))
  (is ((some-fn even?) 2))
  (is ((some-fn even?) 2 4))
  (is (not ((some-fn odd?) 2)))
  (is (not ((some-fn odd?) 2 4)))
  ;; 2 preds
  (is (not ((some-fn even? number?))))
  (is ((some-fn even? number?) 2))
  (is ((some-fn number? odd?) 2))
  (is ((some-fn number? odd?) 2 4))
  ;; 3 preds
  (is (not ((some-fn even? number? #(> % 0)))))
  (is ((some-fn even? number? #(> % 0)) 2))
  (is ((some-fn number? odd? #(> % 0)) 2))
  (is ((some-fn number? odd? #(> % 0)) 2 4)))

(deftest test-max-min-key
  (are [k coll min-item max-item] (and (= min-item (apply min-key k coll))
                                       (= max-item (apply max-key k coll)))
    count ["longest" "a" "xy" "foo" "bar"] "a" "longest"
    - [5 10 15 20 25] 25 5))

(deftest test-update
  (are [result expr] (= result expr)
    {:a [1 2]}   (update {:a [1]} :a conj 2)
    [1]          (update [0] 0 inc)
    ;; missing field = nil
    {:a 1 :b nil} (update {:a 1} :b identity)
    ;; hard-coded arities
    {:a 1} (update {:a 1} :a +)
    {:a 2} (update {:a 1} :a + 1)
    {:a 3} (update {:a 1} :a + 1 1)
    {:a 4} (update {:a 1} :a + 1 1 1)
    ;; rest arity
    {:a 5} (update {:a 1} :a + 1 1 1 1)
    {:a 6} (update {:a 1} :a + 1 1 1 1 1)))

(deftest test-update-vals
  (are [result expr] (= result expr)
    {:a 2 :b 3}   (update-vals {:a 1 :b 2} inc)))

(deftest test-update-keys
  (are [result expr] (= result expr)
    {"a" 1 "b" 2} (update-keys {:a 1 :b 2} name)))

(run-tests)
