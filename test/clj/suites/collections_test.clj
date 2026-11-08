;; conj / nth edge semantics (clj parity, F-011), plus predicate coverage
;; migrated from test/e2e/phase14_counted_reversible.sh.
;;
;; This file needed no registration anywhere — test/clj/run_suites.clj discovers
;; test/clj/suites/*_test.clj by listing the directory.
(ns suites.collections-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- conj: nil is a no-op ON A MAP ONLY ---
;; clj's APersistentMap.cons walks (RT/seq o); seq of nil is nil, so the loop
;; never runs and the map comes back unchanged. Vectors and sets instead take
;; the nil AS an element, so this is not a blanket "conj ignores nil" rule.
(deftest conj-nil
  (testing "a map drops the nil"
    (is (= {:a 1} (conj {:a 1} nil)))
    (is (= {:a 1} (conj (sorted-map :a 1) nil)))
    (is (= {} (conj {} nil))))
  (testing "a vector / set / list KEEPS it — nil is a value there"
    (is (= [1 nil] (conj [1] nil)))
    (is (= #{1 nil} (conj #{1} nil)))
    (is (= '(nil 1) (conj '(1) nil)))))

;; --- conj into a map: what counts as an entry ---
(deftest conj-map-entry-shapes
  (testing "a map, a real entry and a 2-vector all work"
    (is (= {:a 1 :b 2} (conj {:a 1} {:b 2})))
    (is (= {:a 1 :b 2} (conj {:a 1} (first {:b 2}))))
    (is (= {:a 1 :b 2} (conj {:a 1} [:b 2]))))
  (testing "a 2-vector is destructured as [k v] whatever the elements are"
    (is (= {:a 1 [:b 2] [:c 3]} (conj {:a 1} [[:b 2] [:c 3]]))))
  (testing "a non-pair throws — a SEQ of entries is not accepted (clj throws too)"
    (is (thrown? Throwable (conj {:a 1} [:b 2 3])))
    (is (thrown? Throwable (conj {:a 1} :b)))
    (is (thrown? Throwable (conj {:a 1} (list [:b 2] [:c 3]))))))

;; --- nth: an empty coll has nothing at any index ---
;; The list arm walked the tail and so already raised for `(nth '(1) 5)`, but
;; index 0 on an EMPTY list never entered the walk and answered nil.
(deftest nth-out-of-range
  (testing "no default -> raise, empty list included"
    (is (thrown? Throwable (nth '() 0)))
    (is (thrown? Throwable (nth [] 0)))
    (is (thrown? Throwable (nth '(1) 5)))
    (is (thrown? Throwable (nth [1] 5))))
  (testing "with a default -> the default, never a raise"
    (is (= :default (nth '() 0 :default)))
    (is (= :default (nth [] 0 :default)))
    (is (= :default (nth [1] 5 :default)))
    (is (= :default (nth '(1) 5 :default))))
  (testing "in range still works"
    (is (= 2 (nth [1 2] 1)))
    (is (= 2 (nth '(1 2) 1)))
    (is (= 1 (nth '(1) 0))))
  (testing "nil coll is nil at any index (clj RT.nth), not a raise"
    (is (nil? (nth nil 0)))
    (is (= :default (nth nil 3 :default)))))

(deftest core-collection-predicates
  (testing "counted?"
    (is (= [true true true true false false false true true]
           [(counted? [1])
            (counted? {})
            (counted? #{1})
            (counted? (list 1))
            (counted? (lazy-seq (cons 1 nil)))
            (counted? "abc")
            (counted? nil)
            (counted? (range 3))
            (counted? (seq [1 2]))])))
  (testing "reversible?"
    (is (= [true false false true true false false]
           [(reversible? [1])
            (reversible? (list 1))
            (reversible? {})
            (reversible? (sorted-map))
            (reversible? (sorted-set))
            (reversible? "abc")
            (reversible? nil)])))
  (testing "rational?"
    (is (= [true true false true true]
           [(rational? 1/2)
            (rational? 1M)
            (rational? 1.5)
            (rational? 1)
            (rational? 1N)])))
  (testing "seqable?"
    (is (= [true true false true true true true]
           [(seqable? nil)
            (seqable? "x")
            (seqable? 5)
            (seqable? [1])
            (seqable? {})
            (seqable? #{1})
            (seqable? (list 1))])))
  (testing "indexed?"
    (is (= [true false false false false]
           [(indexed? [1])
            (indexed? (list 1))
            (indexed? "x")
            (indexed? (range 3))
            (indexed? (seq [1]))])))
  (testing "qualified-keyword?"
    (is (= [true false false false]
           [(qualified-keyword? :a/b)
            (qualified-keyword? :a)
            (qualified-keyword? 'a/b)
            (qualified-keyword? nil)])))
  (testing "ident?"
    (is (= [true true false true true false]
           [(ident? :a)
            (ident? 'a)
            (ident? "a")
            (ident? :a/b)
            (ident? 'a/b)
            (ident? nil)]))))
