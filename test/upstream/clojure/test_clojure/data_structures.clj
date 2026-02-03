;; data_structures.clj - ClojureWasm equivalent tests
;; Based on Clojure JVM data_structures.clj
;; Known bugs: F55-F65 (see checklist.md) — F66 resolved in T14.5.1

(println "[test/data_structures] running...")

(deftest test-equality
  (testing "nil is not equal to other values"
    (are [x] (not (= nil x))
      true false
      0 0.0
      \space
      ""
      [] #{} {}))

  (testing "vectors equal other seqs"
    (are [x y] (= x y)
      '() []
      '(1) [1]
      '(1 2) [1 2]
      [] '()
      [1] '(1)
      [1 2] '(1 2))
    (is (not= [1 2] '(2 1))))

  (testing "list and vector vs set and map"
    (are [x y] (not= x y)
      [] #{}
      [] {}
      #{} {}
      '(1) #{1}
      [1] #{1})))

(deftest test-count
  (testing "count on various collections"
    (are [x y] (= (count x) y)
      nil 0
      '() 0
      '(1) 1
      '(1 2 3) 3
      [] 0
      [1] 1
      [1 2 3] 3
      #{} 0
      #{1} 1
      #{1 2 3} 3
      {} 0
      {:a 1} 1
      {:a 1 :b 2 :c 3} 3
      "" 0
      "a" 1
      "abc" 3))

  (testing "count of single-element collections"
    (are [x] (= (count [x]) 1)
      nil true false
      0 0.0 "" \space
      '() [] #{} {})))

(deftest test-conj
  (testing "conj on nil"
    (are [x y] (= x y)
      (conj nil 1) '(1)
      (conj nil 3 2 1) '(1 2 3)
      (conj nil nil) '(nil)
      (conj nil nil nil) '(nil nil)
      (conj nil nil nil 1) '(1 nil nil)))

  (testing "conj on list"
    (are [x y] (= x y)
      (conj '() 1) '(1)
      (conj '() 1 2) '(2 1)
      (conj '(2 3) 1) '(1 2 3)
      (conj '(2 3) 1 4 3) '(3 4 1 2 3)
      (conj '() nil) '(nil)))

  (testing "conj on vector"
    (are [x y] (= x y)
      (conj [] 1) [1]
      (conj [] 1 2) [1 2]
      (conj [2 3] 1) [2 3 1]
      (conj [2 3] 1 4 3) [2 3 1 4 3]
      (conj [] nil) [nil]
      (conj [] []) [[]]))

  (testing "conj on map"
    (are [x y] (= x y)
      (conj {} {}) {}
      (conj {} {:a 1}) {:a 1}
      (conj {} {:a 1 :b 2}) {:a 1 :b 2}
      (conj {:a 1} {:a 7}) {:a 7}
      (conj {:a 1} {:b 2}) {:a 1 :b 2}
      (conj {} (first {:a 1})) {:a 1}
      (conj {} [:a 1]) {:a 1}
      (conj {} {nil {}}) {nil {}}))

  (testing "conj on set"
    (are [x y] (= x y)
      (conj #{} 1) #{1}
      (conj #{} 1 2 3) #{1 2 3}
      (conj #{2 3} 1) #{1 2 3}
      (conj #{2 3} 2) #{2 3}
      (conj #{} nil) #{nil}
      (conj #{} #{}) #{#{}})))

(deftest test-peek
  (testing "peek on list"
    (are [x y] (= x y)
      (peek nil) nil
      (peek '()) nil
      (peek '(1)) 1
      (peek '(1 2 3)) 1
      (peek '(nil)) nil)
    (is (empty? (peek '(())))))

  (testing "peek on vector"
    (are [x y] (= x y)
      (peek []) nil
      (peek [1]) 1
      (peek [1 2 3]) 3
      (peek [nil]) nil
      (peek [[]]) [])))

(deftest test-pop
  (testing "pop on list"
    (is (empty? (pop '(1))))
    (is (= (pop '(1 2 3)) '(2 3)))
    (is (empty? (pop '(nil))))
    (is (empty? (pop '(())))))

  (testing "pop on vector"
    (are [x y] (= x y)
      (pop [1]) []
      (pop [1 2 3]) [1 2]
      (pop [nil]) []
      (pop [[]]) [])))

(deftest test-list
  (testing "list? predicate"
    (are [x] (list? x)
      '()
      (list)
      (list 1 2 3)))

  (testing "list construction"
    (are [x y] (= x y)
      (list) '()
      (list 1) '(1)
      (list 1 2) '(1 2)))

  (testing "list nesting"
    (is (= (list 1 (list 2 3)) '(1 (2 3)))))

  (testing "list special cases"
    (are [x y] (= x y)
      (list nil) '(nil)
      (list 1 nil) '(1 nil))
    (is (= 1 (count (list '()))))
    (is (empty? (first (list '()))))))

(deftest test-find
  (testing "find on map"
    (are [x y] (= x y)
      (find {} :a) nil
      (find {:a 1} :a) [:a 1]
      (find {:a 1} :b) nil
      (find {nil 1} nil) [nil 1]
      (find {:a 1 :b 2} :a) [:a 1]
      (find {:a 1 :b 2} :c) nil)))

(deftest test-contains?
  (testing "contains? on maps"
    (are [x y] (= x y)
      (contains? {} :a) false
      (contains? {:a 1} :a) true
      (contains? {:a 1} :b) false
      (contains? {nil 1} nil) true))

  (testing "contains? on sets"
    (are [x y] (= x y)
      (contains? #{} 1) false
      (contains? #{1} 1) true
      (contains? #{1} 2) false
      (contains? #{1 2 3} 1) true))

  (testing "contains? on vectors"
    (are [x y] (= x y)
      (contains? [] 0) false
      (contains? [1] 0) true
      (contains? [1] 1) false
      (contains? [1 2 3] 2) true)))

(deftest test-keys
  (testing "keys on maps"
    (are [x y] (= x y)
      (keys {}) nil
      (keys {:a 1}) '(:a)
      (keys {nil 1}) '(nil))
    (is (= 2 (count (keys {:a 1 :b 2}))))))

(deftest test-vals
  (testing "vals on maps"
    (are [x y] (= x y)
      (vals {}) nil
      (vals {:a 1}) '(1)
      (vals {nil 1}) '(1))
    (is (= 2 (count (vals {:a 1 :b 2}))))))

(deftest test-key
  (testing "key on map entry"
    (are [x] (= (key (first (hash-map x :value))) x)
      nil false true 0 42 :kw)))

(deftest test-val
  (testing "val on map entry"
    (are [x] (= (val (first (hash-map :key x))) x)
      nil false true 0 42 :kw)))

(deftest test-get
  (let [m {:a 1 :b 2 :c {:d 3 :e 4} :f nil nil {:h 5}}]
    (testing "basic get"
      (are [x y] (= x y)
        (get m :a) 1
        (get m :e) nil
        (get m :e 0) 0
        (get m nil) {:h 5}
        (get m :b 0) 2
        (get m :f 0) nil))

    (testing "get-in"
      (are [x y] (= x y)
        (get-in m [:c :e]) 4
        (get-in m [:c :x]) nil
        (get-in m [:f]) nil
        (get-in m []) m
        (get-in m nil) m))))

(deftest test-hash-set
  (testing "set? predicate"
    (are [x] (set? x)
      #{}
      #{1 2}
      (hash-set)
      (hash-set 1 2)))

  (testing "set order"
    (are [x y] (= x y)
      #{1 2} #{2 1}
      (hash-set 1 2) (hash-set 2 1)))

  (testing "hash-set construction"
    (are [x y] (= x y)
      (hash-set) #{}
      (hash-set 1) #{1}
      (hash-set 1 2) #{1 2}))

  (testing "hash-set nesting"
    (is (= (hash-set 1 (hash-set 2 3)) #{1 #{2 3}})))

  (testing "hash-set special cases"
    (are [x y] (= x y)
      (hash-set nil) #{nil}
      (hash-set 1 nil) #{1 nil}
      (hash-set #{}) #{#{}})))

(deftest test-set
  (testing "set? on converted"
    (are [x] (set? (set x))
      '() '(1 2)
      [] [1 2]
      #{} #{1 2}))

  ;; F65: postwalk-replace cannot handle set literal #{x} in are template
  ;; Workaround: use is instead of are for set literal comparisons
  (testing "set uniqueness"
    (is (= (set [nil nil]) #{nil}))
    (is (= (set [false false]) #{false}))
    (is (= (set [true true]) #{true}))
    (is (= (set [0 0]) #{0}))
    (is (= (set [42 42]) #{42}))
    (is (= (set [:kw :kw]) #{:kw})))

  (testing "set conversion"
    (is (= (set '()) #{}))
    (is (= (set '(1 2)) #{1 2}))
    (is (= (set []) #{}))
    (is (= (set [1 2]) #{1 2}))
    (is (= (set #{}) #{}))
    (is (= (set #{1 2}) #{1 2}))))

(deftest test-disj
  (testing "disj identity"
    (are [x] (= (disj x) x)
      nil
      #{}
      #{1 2 3}))

  (testing "disj operations"
    (are [x y] (= x y)
      (disj nil :a) nil
      (disj #{} :a) #{}
      (disj #{:a} :a) #{}
      (disj #{:a} :c) #{:a}
      (disj #{:a :b :c :d} :a) #{:b :c :d}
      (disj #{nil} nil) #{}
      (disj #{#{}} #{}) #{})))

(deftest test-assoc
  (testing "assoc on vectors and maps"
    (are [x y] (= x y)
      [4] (assoc [] 0 4)
      [5 -7] (assoc [] 0 5 1 -7)
      {:a 1} (assoc {} :a 1)
      {nil 1} (assoc {} nil 1)
      {:a 2 :b -2} (assoc {} :b -2 :a 2))))

(run-tests)
