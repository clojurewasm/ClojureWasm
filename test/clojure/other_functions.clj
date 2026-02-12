;; Ported from clojure/test_clojure/other_functions.clj
;; Tests for identity, fnil, comp, complement, constantly, juxt, partial,
;; every-pred, some-fn, max/min-key, update, update-vals, update-keys,
;; transduce, cat, dedupe, halt-when, sequence, random-sample, replicate,
;; comparator, xml-seq, mapv, lazy-cat, when-first, assert, deref/reduced, conj
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

;; --- Spec predicates (1.9) ---

(deftest test-ident?
  (is (true? (ident? :foo)))
  (is (true? (ident? 'bar)))
  (is (true? (ident? :a/b)))
  (is (true? (ident? 'a/b)))
  (is (false? (ident? "foo")))
  (is (false? (ident? 42)))
  (is (false? (ident? nil))))

(deftest test-simple-ident?
  (is (true? (simple-ident? :foo)))
  (is (false? (simple-ident? :a/b)))
  (is (true? (simple-ident? 'bar)))
  (is (false? (simple-ident? 'a/b)))
  (is (false? (simple-ident? "foo")))
  (is (false? (simple-ident? 42))))

(deftest test-qualified-ident?
  (is (true? (qualified-ident? :a/b)))
  (is (true? (qualified-ident? 'a/b)))
  (is (false? (qualified-ident? :foo)))
  (is (false? (qualified-ident? 'bar)))
  (is (false? (qualified-ident? "a/b")))
  (is (false? (qualified-ident? 42))))

(deftest test-simple-symbol?
  (is (true? (simple-symbol? 'foo)))
  (is (false? (simple-symbol? 'a/b)))
  (is (false? (simple-symbol? :foo)))
  (is (false? (simple-symbol? "foo"))))

(deftest test-qualified-symbol?
  (is (true? (qualified-symbol? 'a/b)))
  (is (false? (qualified-symbol? 'foo)))
  (is (false? (qualified-symbol? :a/b)))
  (is (false? (qualified-symbol? "a/b"))))

(deftest test-distinct?
  (is (true? (distinct? 1)))
  (is (true? (distinct? 1 2)))
  (is (false? (distinct? 1 1)))
  (is (true? (distinct? 1 2 3)))
  (is (false? (distinct? 1 2 1)))
  (is (true? (distinct? 1 2 3 4 5)))
  (is (false? (distinct? 1 2 3 4 1)))
  (is (true? (distinct? :a :b :c)))
  (is (false? (distinct? :a :b :a))))

(deftest test-run!
  (let [a (atom [])]
    (run! (fn [x] (swap! a conj x)) [1 2 3])
    (is (= [1 2 3] @a)))
  (is (nil? (run! identity [1 2 3]))))

(deftest test-nthnext
  (is (= '(3 4 5) (nthnext [1 2 3 4 5] 2)))
  (is (= '(1 2 3) (nthnext '(1 2 3) 0)))
  (is (nil? (nthnext [1 2] 5)))
  (is (nil? (nthnext [] 0))))

(deftest test-nthrest
  (is (= '(3 4 5) (nthrest [1 2 3 4 5] 2)))
  (is (= [1 2 3] (nthrest [1 2 3] 0)))
  (is (= () (nthrest [1 2] 5))))

(deftest test-take-last
  (is (= '(4 5) (take-last 2 [1 2 3 4 5])))
  (is (= '(1 2 3) (take-last 10 [1 2 3])))
  (is (nil? (take-last 0 [1 2 3])))
  (is (nil? (take-last 2 []))))

(deftest test-parse-boolean
  (is (true? (parse-boolean "true")))
  (is (false? (parse-boolean "false")))
  (is (nil? (parse-boolean "yes")))
  (is (nil? (parse-boolean "1")))
  (is (thrown? Exception (parse-boolean nil))))

(deftest test-reductions
  (is (= [1 3 6 10] (vec (reductions + [1 2 3 4]))))
  (is (= [10 11 13 16] (vec (reductions + 10 [1 2 3]))))
  (is (= [0] (vec (reductions + []))))
  (is (= [1] (vec (reductions + [1])))))

(deftest test-take-nth
  (is (= [1 3 5] (vec (take-nth 2 [1 2 3 4 5 6]))))
  (is (= [1 4 7] (vec (take-nth 3 [1 2 3 4 5 6 7 8 9]))))
  (is (= [1 2 3] (vec (take-nth 1 [1 2 3]))))
  (is (= [] (vec (take-nth 2 [])))))

(deftest test-replace-fn
  (is (= [:a :b 3 4] (replace {1 :a 2 :b} [1 2 3 4])))
  (is (= [:a :b 3 4] (vec (replace {1 :a 2 :b} '(1 2 3 4)))))
  (is (= [1 2 3] (replace {} [1 2 3])))
  (is (= [:x :x :x] (replace {1 :x 2 :x 3 :x} [1 2 3]))))

(deftest test-completing-fn
  (is (= 7 (let [f (completing +)] (f 3 4))))
  (is (= "42" (let [f (completing + str)] (f 42))))
  (is (= 0 (let [f (completing +)] (f)))))

(deftest test-tree-seq-fn
  (is (= [[1 [2 3]] 1 [2 3] 2 3]
         (vec (tree-seq vector? seq [1 [2 3]]))))
  (is (= [1] (vec (tree-seq vector? seq 1))))
  (is (= [[]] (vec (tree-seq vector? seq [])))))

(deftest test-seqable-pred
  (is (true? (seqable? [1 2])))
  (is (true? (seqable? '(1))))
  (is (true? (seqable? {:a 1})))
  (is (true? (seqable? #{1})))
  (is (true? (seqable? "hi")))
  (is (true? (seqable? nil)))
  (is (false? (seqable? 42)))
  (is (false? (seqable? true))))

(deftest test-counted-pred
  (is (true? (counted? [1 2])))
  (is (true? (counted? '(1))))
  (is (true? (counted? {:a 1})))
  (is (true? (counted? #{1})))
  (is (false? (counted? nil))))

(deftest test-bounded-count-fn
  (is (= 3 (bounded-count 10 [1 2 3])))
  (is (= 5 (bounded-count 5 [1 2 3 4 5 6 7])))
  (is (= 0 (bounded-count 10 []))))

(deftest test-indexed-pred
  (is (true? (indexed? [1 2])))
  (is (false? (indexed? '(1))))
  (is (false? (indexed? #{1}))))

(deftest test-reversible-pred
  (is (true? (reversible? [1 2])))
  (is (false? (reversible? '(1)))))

;; === T18.6.2-3: Transducer & Pure Clojure additions ===

(deftest test-transduce
  (is (= 14 (transduce (map inc) + [1 2 3 4])))
  (is (= 24 (transduce (map inc) + 10 [1 2 3 4])))
  (is (= 0 (transduce (map inc) + [])))
  (is (= 9 (transduce (filter odd?) + [1 2 3 4 5])))
  (is (= [2 3 4] (into [] (map inc) [1 2 3])))
  (is (= [1 3 5] (into [] (filter odd?) [1 2 3 4 5]))))

(deftest test-cat
  (is (= [1 2 3 4 5] (into [] cat [[1 2] [3 4] [5]])))
  (is (= [1 2 3] (into [] cat [[1] [2] [3]])))
  (is (= [] (into [] cat []))))

(deftest test-dedupe
  (is (= [1 2 3 1] (into [] (dedupe) [1 1 2 2 3 3 1 1])))
  (is (= [1 2 3 1] (into [] (dedupe) [1 2 2 3 1 1])))
  (is (= [1 2 3] (dedupe [1 1 2 2 3 3]))))

(deftest test-halt-when
  (is (= 4 (into [] (halt-when (fn [x] (> x 3))) [1 2 3 4 5])))
  (is (= [1 2 3] (into [] (halt-when (fn [x] (> x 10))) [1 2 3]))))

(deftest test-sequence
  (is (= '(1 2 3) (sequence [1 2 3])))
  (is (= () (sequence nil)))
  (is (= () (sequence [])))
  (is (= 3 (count (sequence [1 2 3])))))

(deftest test-random-sample
  (is (<= (count (random-sample 0.5 (range 100))) 100))
  (is (= 0 (count (random-sample 0.0 [1 2 3]))))
  (is (= 3 (count (into [] (random-sample 1.0) [1 2 3])))))

(deftest test-replicate
  (is (= '(:x :x :x) (replicate 3 :x)))
  (is (empty? (replicate 0 :x))))

(deftest test-comparator
  (let [cmp (comparator <)]
    (is (= -1 (cmp 1 2)))
    (is (= 1 (cmp 2 1)))
    (is (= 0 (cmp 1 1)))))

(deftest test-xml-seq
  (let [root {:tag :a :content [{:tag :b :content []} "text"]}]
    (is (= 3 (count (xml-seq root))))))

(deftest test-mapv
  (is (= [2 3 4] (mapv inc [1 2 3])))
  (is (vector? (mapv inc [1 2 3])))
  (is (= [] (mapv inc []))))

(deftest test-lazy-cat
  (is (= [1 2 3 4 5] (vec (lazy-cat [1 2] [3 4] [5]))))
  (is (= [] (vec (lazy-cat)))))

(deftest test-when-first
  (is (= "first=1" (when-first [x [1 2 3]] (str "first=" x))))
  (is (nil? (when-first [x []] (str "first=" x)))))

(deftest test-assert
  (is (= :ok (do (assert true) :ok)))
  (is (= "caught" (try (assert false "boom") (catch Error e "caught")))))

(deftest test-deref-reduced
  (is (= 42 (deref (reduced 42))))
  (is (= 99 @(reduced 99))))

(deftest test-conj-arity
  (is (= [] (conj)))
  (is (= [1] (conj [1]))))

(run-tests)
