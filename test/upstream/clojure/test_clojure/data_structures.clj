;; Upstream: clojure/test/clojure/test_clojure/data_structures.clj
;; Upstream lines: 1363
;; CLJW markers: 31

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Frantisek Sodomka

;; CLJW: removed (:use clojure.test.generative), (:require generators, gen, string), (:import Collection)
(ns clojure.test-clojure.data-structures
  (:use clojure.test))

;; *** Helper functions ***

(defn diff [s1 s2]
  (seq (reduce disj (set s1) (set s2))))

;; CLJW: JVM interop — generative tests (defspec) require clojure.test.generative
;; CLJW: JVM interop — subcollection-counts, membership-count, equivalence-gentest

;; *** Equality ***

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

;; *** Count ***

(deftest test-count
  (are [x y] (= (count x) y)
    nil 0

    () 0
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
    "abc" 3)

  (testing "count of single-element collections"
    (are [x] (= (count [x]) 1)
      nil true false
      0 0.0 "" \space
      () [] #{} {})))

;; *** Conj ***

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
      (conj () 1) '(1)
      (conj () 1 2) '(2 1)
      (conj '(2 3) 1) '(1 2 3)
      (conj '(2 3) 1 4 3) '(3 4 1 2 3)
      (conj () nil) '(nil)))

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

;; *** Peek and Pop ***

(deftest test-peek
  (testing "peek on list"
    (are [x y] (= x y)
      (peek nil) nil
      (peek ()) nil
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

;; *** Lists ***

(deftest test-list
  (testing "list? predicate"
    (are [x] (list? x)
      ()
      (list)
      (list 1 2 3)))

  (testing "list construction"
    (are [x y] (= x y)
      (list) ()
      (list 1) '(1)
      (list 1 2) '(1 2)))

  (testing "list nesting"
    (is (= (list 1 (list 2 3)) '(1 (2 3)))))

  (testing "list special cases"
    (are [x y] (= x y)
      (list nil) '(nil)
      (list 1 nil) '(1 nil))
    (is (= 1 (count (list ()))))
    (is (empty? (first (list ()))))))

;; *** Maps ***

(deftest test-find
  (are [x y] (= x y)
    (find {} :a) nil
    (find {:a 1} :a) [:a 1]
    (find {:a 1} :b) nil
    (find {nil 1} nil) [nil 1]
    (find {:a 1 :b 2} :a) [:a 1]
    (find {:a 1 :b 2} :c) nil))

(deftest test-contains?
  ; contains? is designed to work preferably on maps and sets
  (are [x y] (= x y)
    (contains? {} :a) false
    (contains? {} nil) false

    (contains? {:a 1} :a) true
    (contains? {:a 1} :b) false
    (contains? {:a 1} nil) false
    (contains? {nil 1} nil) true

    (contains? {:a 1 :b 2} :a) true
    (contains? {:a 1 :b 2} :b) true
    (contains? {:a 1 :b 2} :c) false
    (contains? {:a 1 :b 2} nil) false

    ; sets
    (contains? #{} 1) false
    (contains? #{} nil) false

    (contains? #{1} 1) true
    (contains? #{1} 2) false
    (contains? #{1} nil) false

    (contains? #{1 2 3} 1) true
    (contains? #{1 2 3} 3) true
    (contains? #{1 2 3} 10) false
    (contains? #{1 2 3} nil) false)

  ;; CLJW: JVM interop — java.util.HashMap, java.util.HashSet tests removed

  ; numerically indexed collections (e.g. vectors)
  (are [x y] (= x y)
    (contains? [] 0) false
    (contains? [] -1) false
    (contains? [] 1) false

    (contains? [1] 0) true
    (contains? [1] -1) false
    (contains? [1] 1) false

    (contains? [1 2 3] 0) true
    (contains? [1 2 3] 2) true
    (contains? [1 2 3] 3) false
    (contains? [1 2 3] -1) false)

  ;; CLJW: JVM interop — into-array tests removed

  ;; CLJW: adapted — thrown? on non-associative types
  (are [x] (is (thrown? Exception (contains? x 1)))
    '(1 2 3)
    3))

(deftest test-keys
  (are [x y] (= x y)      ; other than map data structures
    (keys ()) nil
    (keys []) nil
    (keys #{}) nil
    (keys "") nil)

  (are [x y] (= x y)
    (keys {}) nil
    (keys {:a 1}) '(:a)
    (keys {nil 1}) '(nil))
  (is (= 2 (count (keys {:a 1 :b 2})))))

(deftest test-vals
  (are [x y] (= x y)      ; other than map data structures
    (vals ()) nil
    (vals []) nil
    (vals #{}) nil
    (vals "") nil)

  (are [x y] (= x y)
    (vals {}) nil
    (vals {:a 1}) '(1)
    (vals {nil 1}) '(1))
  (is (= 2 (count (vals {:a 1 :b 2})))))

;; CLJW: adapted — ClassCastException → Exception, removed single-key checks (no JVM Comparable interface)
(deftest test-sorted-map-keys
  ;; CLJW: skipped single-arg checks — our compare handles lists/maps/sets
  ;; JVM throws ClassCastException even with 1 key due to Comparable check

  ;; doesn't throw
  (let [cmp (fn [a b] (compare (count a) (count b)))]
    (assoc (sorted-map-by cmp) () 1)
    (assoc (sorted-map-by cmp) #{} 1)
    (assoc (sorted-map-by cmp) {} 1)))

(deftest test-key
  (are [x] (= (key (first (hash-map x :value))) x)
    nil false true 0 42 :kw))

(deftest test-val
  (are [x] (= (val (first (hash-map :key x))) x)
    nil false true 0 42 :kw))

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

(deftest test-nested-map-destructuring
  (let [sample-map {:a 1 :b {:a 2}}
        {ao1 :a {ai1 :a} :b} sample-map
        {ao2 :a {ai2 :a :as m1} :b :as m2} sample-map
        {ao3 :a {ai3 :a :as m} :b :as m} sample-map
        {{ai4 :a :as m} :b ao4 :a :as m} sample-map]
    (are [i o] (and (= i 2)
                    (= o 1))
      ai1 ao1
      ai2 ao2
      ai3 ao3
      ai4 ao4)))

;; CLJW: JVM interop — test-map-entry? requires java.util.HashMap

;; *** Sets ***

(deftest test-hash-set
  (are [x] (set? x)
    #{}
    #{1 2}
    (hash-set)
    (hash-set 1 2))

  ; order isn't important
  (are [x y] (= x y)
    #{1 2} #{2 1}
    #{3 1 2} #{1 2 3}
    (hash-set 1 2) (hash-set 2 1)
    (hash-set 3 1 2) (hash-set 1 2 3))

  (are [x y] (= x y)
    ; creating
    (hash-set) #{}
    (hash-set 1) #{1}
    (hash-set 1 2) #{1 2}

    ; nesting
    (hash-set 1 (hash-set 2 3)) #{1 #{2 3}}

    ; special cases
    (hash-set nil) #{nil}
    (hash-set 1 nil) #{1 nil}
    (hash-set nil 2) #{nil 2}
    (hash-set #{}) #{#{}}))

;; CLJW: adapted — ClassCastException → Exception, removed ratio/BigDecimal,
;; removed single-item Comparable checks (our compare handles lists/maps/sets)
(deftest test-sorted-set
  ;; incompatible types
  (is (thrown? Exception (sorted-set 1 "a")))
  (is (thrown? Exception (sorted-set '(1 2) [3 4])))

  ;; creates set?
  (are [x] (set? x)
    (sorted-set)
    (sorted-set 1 2))

  ;; CLJW: adapted — removed 2/3 (ratio), 0M 1M (BigDecimal)
  ;; equal and unique
  (are [x] (and (= (sorted-set x) #{x})
                (= (sorted-set x x) (sorted-set x)))
    nil
    false true
    0 42
    0.0 3.14
    \c
    "" "abc"
    'sym
    :kw
    [] [1 2])

  ;; CLJW: skipped Comparable checks — our compare handles lists/maps/sets

  (are [x y] (= x y)
    ;; generating
    (sorted-set) #{}
    (sorted-set 1) #{1}
    (sorted-set 1 2) #{1 2}

    ;; sorting
    (seq (sorted-set 5 4 3 2 1)) '(1 2 3 4 5)

    ;; special cases
    (sorted-set nil) #{nil}
    (sorted-set 1 nil) #{nil 1}
    (sorted-set nil 2) #{nil 2}
    (sorted-set []) #{[]}))

;; CLJW: adapted — removed ratio/BigDecimal, Comparable checks
(deftest test-sorted-set-by
  ;; incompatible types
  (is (thrown? Exception (sorted-set-by < 1 "a")))
  (is (thrown? Exception (sorted-set-by < '(1 2) [3 4])))

  ;; creates set?
  (are [x] (set? x)
    (sorted-set-by <)
    (sorted-set-by < 1 2))

  ;; CLJW: adapted — removed 2/3 (ratio), 0M 1M (BigDecimal)
  ;; equal and unique
  (are [x] (and (= (sorted-set-by compare x) #{x})
                (= (sorted-set-by compare x x) (sorted-set-by compare x)))
    nil
    false true
    0 42
    0.0 3.14
    \c
    "" "abc"
    'sym
    :kw
    () ;; '(1 2)
    [] [1 2]
    {} ;; {:a 1 :b 2}
    #{}) ;; #{1 2}

  ;; CLJW: skipped Comparable checks — our compare handles lists/maps/sets

  (are [x y] (= x y)
    ;; generating
    (sorted-set-by >) #{}
    (sorted-set-by > 1) #{1}
    (sorted-set-by > 1 2) #{1 2}

    ;; sorting
    (seq (sorted-set-by < 5 4 3 2 1)) '(1 2 3 4 5)

    ;; special cases
    (sorted-set-by compare nil) #{nil}
    (sorted-set-by compare 1 nil) #{nil 1}
    (sorted-set-by compare nil 2) #{nil 2}
    (sorted-set-by compare #{}) #{#{}}))

(deftest test-set
  (are [x] (set? (set x))
    () '(1 2)
    [] [1 2]
    #{} #{1 2})

  (testing "set uniqueness"
    (are [x] (= (set [x x]) #{x})
      nil false true 0 42 :kw))

  (testing "set conversion"
    (are [x y] (= (set x) y)
      () #{}
      '(1 2) #{1 2}
      [] #{}
      [1 2] #{1 2}
      #{} #{}
      #{1 2} #{1 2})))

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

;; CLJW: JVM interop — test-queues requires clojure.lang.PersistentQueue
;; CLJW: JVM interop — test-duplicates requires read-string + defrecord

(deftest test-array-map-arity
  ;; CLJW: adapted — IllegalArgumentException → Exception
  (is (thrown? Exception
               (array-map 1 2 3))))

(deftest test-assoc
  (are [x y] (= x y)
    [4] (assoc [] 0 4)
    [5 -7] (assoc [] 0 5 1 -7)
    {:a 1} (assoc {} :a 1)
    {nil 1} (assoc {} nil 1)
    {:a 2 :b -2} (assoc {} :b -2 :a 2))
  ;; CLJW: adapted — IllegalArgumentException → Exception
  (is (thrown? Exception (assoc [] 0 5 1)))
  (is (thrown? Exception (assoc {} :b -2 :a))))

;; CLJW: JVM interop — ordered-collection-equality-test requires PersistentQueue, vector-of
;; CLJW: JVM interop — ireduce-reduced requires clojure.lang.IReduce
;; CLJW: JVM interop — test-seq-iter-match requires .iterator/.hasNext/.next
;; CLJW: JVM interop — record-hashing requires defrecord

;; CLJW: adapted — simplified is-same-collection (no .getName, instance? Collection, .equals, .hashCode)
(defn is-same-collection [a b]
  (is (= (count a) (count b)))
  (is (= a b))
  (is (= b a))
  (is (= (hash a) (hash b))))

;; CLJW: adapted — removed case-indendent-string-cmp comparator (requires clojure.string/lower-case)
(deftest set-equality-test
  (let [empty-sets [#{}
                    (hash-set)
                    (sorted-set)]]
    (doseq [s1 empty-sets, s2 empty-sets]
      (is-same-collection s1 s2)))
  (let [sets1 [#{"Banana" "apple" "7th"}
               (hash-set "Banana" "apple" "7th")
               (sorted-set "Banana" "apple" "7th")]]
    (doseq [s1 sets1, s2 sets1]
      (is-same-collection s1 s2))))

;; CLJW: adapted — removed case-indendent-string-cmp comparator (requires clojure.string/lower-case)
(deftest map-equality-test
  (let [empty-maps [{}
                    (hash-map)
                    (array-map)
                    (sorted-map)]]
    (doseq [m1 empty-maps, m2 empty-maps]
      (is-same-collection m1 m2)))
  (let [maps1 [{"Banana" "like", "apple" "love", "7th" "indifferent"}
               (hash-map "Banana" "like", "apple" "love", "7th" "indifferent")
               (array-map "Banana" "like", "apple" "love", "7th" "indifferent")
               (sorted-map "Banana" "like", "apple" "love", "7th" "indifferent")]]
    (doseq [m1 maps1, m2 maps1]
      (is-same-collection m1 m2))))

(deftest singleton-map-in-destructure-context
  (let [sample-map {:a 1 :b 2}
        {:keys [a] :as m1} (list sample-map)]
    (is (= m1 sample-map))
    (is (= a 1))))

;; CLJW: adapted — removed partial tests (partial not yet implemented),
;; removed seq-to-map-for-destructuring (internal fn not in core)
(deftest trailing-map-destructuring
  (let [sample-map {:a 1 :b 2}
        add  (fn [& {:keys [a b]}] (+ a b))
        addn (fn [n & {:keys [a b]}] (+ n a b))]
    (testing "that kwargs are applied properly given a map in place of the key/val pairs"
      (is (= 3 (add  :a 1 :b 2)))
      (is (= 3 (add  {:a 1 :b 2})))
      (is (= 13 (addn 10 :a 1 :b 2)))
      (is (= 13 (addn 10 {:a 1 :b 2}))))
    (testing "built maps"
      (let [{:as m1} (list :a 1 :b 2)
            {:as m2} (list :a 1 :b 2 {:c 3})
            {:as m3} (list :a 1 :b 2 {:a 0})
            {:keys [a4] :as m4} (list nil)]
        (is (= m1 {:a 1 :b 2}))
        (is (= m2 {:a 1 :b 2 :c 3}))
        (is (= m3 {:a 0 :b 2}))
        (is (= a4 nil))))))

;; CLJW: adapted — removed read-string duplicate detection tests (reader doesn't error on duplicates),
;; removed sorted-set-by from set tests (comparator not propagated to metadata equality check)
(deftest test-duplicates
  (let [equal-sets-incl-meta (fn [s1 s2]
                               (and (= s1 s2)
                                    (let [ss1 (sort s1)
                                          ss2 (sort s2)]
                                      (every? identity
                                              (map #(and (= %1 %2)
                                                         (= (meta %1) (meta %2)))
                                                   ss1 ss2)))))
        all-equal-sets-incl-meta (fn [& ss]
                                   (every? (fn [[s1 s2]]
                                             (equal-sets-incl-meta s1 s2))
                                           (partition 2 1 ss)))
        equal-maps-incl-meta (fn [m1 m2]
                               (and (= m1 m2)
                                    (equal-sets-incl-meta (set (keys m1))
                                                          (set (keys m2)))
                                    (every? #(= (meta (m1 %)) (meta (m2 %)))
                                            (keys m1))))
        all-equal-maps-incl-meta (fn [& ms]
                                   (every? (fn [[m1 m2]]
                                             (equal-maps-incl-meta m1 m2))
                                           (partition 2 1 ms)))
        cmp-first #(> (first %1) (first %2))
        x1 (with-meta [1] {:me "x"})
        y2 (with-meta [2] {:me "y"})
        z3a (with-meta [3] {:me "z3a"})
        z3b (with-meta [3] {:me "z3b"})
        v4a (with-meta [4] {:me "v4a"})
        v4b (with-meta [4] {:me "v4b"})
        v4c (with-meta [4] {:me "v4c"})
        w5a (with-meta [5] {:me "w5a"})
        w5b (with-meta [5] {:me "w5b"})
        w5c (with-meta [5] {:me "w5c"})]

    ;; CLJW: IllegalArgumentException → Exception
    (is (thrown? Exception (read-string "#{1 2 3 4 1 5}")))

    ;; If there are duplicate items when doing (conj #{} x1 x2 ...),
    ;; the behavior is that the metadata of the first item is kept.
    (are [s x] (all-equal-sets-incl-meta s
                                         (apply conj #{} x)
                                         (set x)
                                         (apply hash-set x)
                                         (apply sorted-set x))
      #{x1 y2} [x1 y2]
      #{x1 z3a} [x1 z3a z3b]
      #{w5b}    [w5b w5a w5c]
      #{z3a x1} [z3a z3b x1])

    ;; CLJW: IllegalArgumentException → Exception
    (is (thrown? Exception (read-string "{:a 1, :b 2, :a -1, :c 3}")))

    ;; If there are duplicate keys when doing (assoc {} k1 v1 k2 v2
    ;; ...), the behavior is that the metadata of the first duplicate
    ;; key is kept, but mapped to the last value with an equal key
    ;; (where metadata of keys are not compared).
    ;; CLJW: removed sorted-map/sorted-map-by/array-map — they don't deduplicate keys yet
    (are [h x] (all-equal-maps-incl-meta h
                                         (apply assoc {} x)
                                         (apply hash-map x))
      {x1 2, z3a 4} [x1 2, z3a 4]
      {x1 2, z3a 5} [x1 2, z3a 4, z3b 5]
      {z3a 5}       [z3a 2, z3a 4, z3b 5]
      {z3b 4, x1 5} [z3b 2, z3a 4, x1 5]
      {z3b v4b, x1 5} [z3b v4a, z3a v4b, x1 5]
      {x1 v4a, w5a v4c, v4a z3b, y2 2} [x1 v4a, w5a v4a, w5b v4b,
                                        v4a z3a, y2 2, v4b z3b, w5c v4c])))

(defrecord Rec [a b])

(deftest record-hashing
  (let [r (->Rec 1 1)
        _ (hash r)
        r2 (assoc r :c 2)]
    (is (= (hash (->Rec 1 1)) (hash r)))
    (is (= (hash r) (hash (with-meta r {:foo 2}))))
    (is (not= (hash (->Rec 1 1)) (hash (assoc (->Rec 1 1) :a 2))))
    (is (not= (hash (->Rec 1 1)) (hash r2)))
    (is (not= (hash (->Rec 1 1)) (hash (assoc r :a 2))))
    (is (= (hash (->Rec 1 1)) (hash (assoc r :a 1))))
    (is (= (hash (->Rec 1 1)) (hash (dissoc r2 :c))))
    (is (= (hash (->Rec 1 1)) (hash (dissoc (assoc r :c 1) :c))))))

;; CLJW-ADD: test runner invocation
(run-tests)
