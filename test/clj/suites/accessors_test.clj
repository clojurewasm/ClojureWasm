;; Map-entry accessor + associative-arg parity (clj parity, F-011).
;;
;; Run by `test/clj/run_suites.clj` — one cljw process for the whole file,
;; instead of one process per assertion the way the bash e2e tier works.
(ns suites.accessors-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.walk]))

;; --- key / val require an actual map entry ---
;; cljw's map entries are a DISTINCT type, so `key`/`val` throw on a plain
;; vector / nil / list the way clj does (a 2-vector is not a Map$Entry).
(deftest key-val
  (testing "on a real map entry (from seq-ing a map)"
    (is (= :a (key (first {:a 1}))))
    (is (= 1  (val (first {:a 1}))))
    (is (= '(:a :b) (map key {:a 1 :b 2})))
    (is (= 3 (reduce (fn [acc e] (+ acc (val e))) 0 {:a 1 :b 2}))))
  (testing "a non-entry throws — plain vector / nil / list"
    (is (thrown? Throwable (key [:k :v])))
    (is (thrown? Throwable (val [:k :v])))
    (is (thrown? Throwable (key nil)))
    (is (thrown? Throwable (val nil)))
    (is (thrown? Throwable (key '(1 2))))))

;; --- EVERY map producer yields map entries, sorted ones included ---
;; The sorted walkers used to build plain 2-vectors, so `(key (first
;; (sorted-map …)))` threw while the hash-map path worked. AD-032 promises a
;; cljw MapEntry for these seq-views; this locks all four producers together.
(deftest map-entry-producers
  (testing "map-entry? holds across hash / sorted / java surfaces"
    (is (map-entry? (first {:a 1})))
    (is (map-entry? (first (sorted-map :a 1))))
    (is (map-entry? (first (seq (java.util.HashMap. {1 :a})))))
    (is (map-entry? (first (seq (java.util.TreeMap. {1 :a}))))))
  (testing "an entry is also a vector, as in clj"
    (is (vector? (first (sorted-map :a 1)))))
  (testing "rseq / subseq / rsubseq walkers too"
    (is (map-entry? (first (rseq (sorted-map :a 1 :b 2)))))
    (is (map-entry? (first (subseq (sorted-map 1 :a 2 :b 3 :c) >= 2))))
    (is (map-entry? (first (rsubseq (sorted-map 1 :a 2 :b 3 :c) <= 2)))))
  (testing "so key/val work over every one of them"
    (is (= '(:a :b) (map key (seq (sorted-map :b 2 :a 1)))))
    (is (= '(1 2) (map val (seq (sorted-map :b 2 :a 1)))))
    (is (= '(:b :a) (map key (rseq (sorted-map :a 1 :b 2)))))
    (is (= '(1 2 3) (map key (seq (java.util.TreeMap. {3 :c 1 :a 2 :b})))))
    (is (= '(:a :b :c) (map val (seq (java.util.TreeMap. {3 :c 1 :a 2 :b})))))))

;; --- find / .entryAt / MapEntry. / walk all yield REAL entries ---
;; Found by an exhaustive producer sweep after `key`/`val` began requiring an
;; entry: `find` built a plain 2-vector, and it also backs `.entryAt`, so every
;; Associative host-method path inherited the bug. clojure.walk had the same
;; defect when rebuilding a map.
(deftest find-and-friends-yield-entries
  (testing "find over every associative kind"
    (is (map-entry? (find {:a 1} :a)))
    (is (map-entry? (find (sorted-map :a 1) :a)))
    (is (map-entry? (find [10 20] 0)))              ; a vector is associative by index
    (is (nil? (find {:a 1} :missing)))              ; absent is still nil, not an entry
    (is (= :a (key (find {:a 1} :a))))
    (is (= 1 (val (find {:a 1} :a))))
    (is (= 0 (key (find [10 20] 0))))
    (is (= 10 (val (find [10 20] 0)))))
  (testing "find distinguishes absent from present-but-nil"
    (is (nil? (find {:a nil} :missing)))
    (is (map-entry? (find {:a nil} :a)))
    (is (nil? (val (find {:a nil} :a)))))
  (testing "the MapEntry constructor"
    (is (map-entry? (MapEntry. :a 1)))
    (is (= :a (key (MapEntry. :a 1))))
    (is (= 2 (val (new clojure.lang.MapEntry :b 2)))))
  (testing ".entryAt routes through find, so it yields an entry too"
    (is (map-entry? (.entryAt {:a 1} :a)))
    (is (= :a (key (.entryAt {:a 1} :a))))))

;; --- clojure.walk hands the walk fn a real entry, and takes either shape back ---
(deftest walk-map-entries
  (testing "the fn receives an entry it can key/val"
    (is (= {:a 1} (clojure.walk/postwalk (fn [x] (when (map-entry? x) (key x)) x) {:a 1})))
    (is (= {:a 2} (clojure.walk/postwalk
                    (fn [x] (if (map-entry? x) [(key x) (inc (val x))] x))
                    {:a 1}))))
  (testing "identity walk survives on both map representations"
    ;; >8 keys forces the HAMT path, which is a separate rebuild site
    (let [big (zipmap (range 12) (range 12))]
      (is (= big (clojure.walk/postwalk identity big)))))
  (testing "returning a plain 2-vector from the walk fn is still accepted"
    (is (= {:a 9} (clojure.walk/postwalk
                    (fn [x] (if (map-entry? x) [(key x) 9] x))
                    {:a 1}))))
  ;; The walk must RECURSE INTO an entry — transform both its key and its val.
  ;; When entries became a distinct type the dispatches still matched only
  ;; `.vector`, so an entry fell through to the scalar arm and nothing inside a
  ;; map was transformed. The giveaway was NESTED: the outer key converted and
  ;; the inner one did not, so a one-level test would have passed.
  (testing "values nested inside a map are transformed"
    (is (= {:a 10 :b [20 30]}
           (clojure.walk/postwalk (fn [x] (if (number? x) (* x 10) x))
                                  {:a 1 :b [2 3]}))))
  (testing "keys are transformed at EVERY depth, not just the top"
    (is (= {:a {:b 1}} (clojure.walk/keywordize-keys {"a" {"b" 1}})))
    (is (= {:a [{:b 1}]} (clojure.walk/keywordize-keys {"a" [{"b" 1}]})))
    (is (= {"a" {"b" 1}} (clojure.walk/stringify-keys {:a {:b 1}}))))
  (testing "replace reaches nested maps"
    (is (= {:x 1 :nested {:x 2}}
           (clojure.walk/prewalk-replace {:a :x} {:a 1 :nested {:a 2}})))
    (is (= {:x 1 :y 2}
           (clojure.walk/postwalk-replace {:a :x :b :y} {:a 1 :b 2})))))

;; --- select-keys: associative-or-nil, else throw ---
;; JVM RT/find casts a non-Associative, non-nil arg to Map, so a string / list
;; / number throws rather than silently answering {}.
(deftest select-keys-associative
  (testing "associative and nil arguments"
    (is (= {:a 1 :c 3} (select-keys {:a 1 :b 2 :c 3} [:a :c])))
    (is (= {} (select-keys nil [:a])))
    (is (= {0 10 2 30} (select-keys [10 20 30] [0 2])))
    (is (= {} (select-keys {:a 1} []))))
  (testing "a non-associative argument throws"
    (is (thrown? Throwable (select-keys "" [:a])))
    (is (thrown? Throwable (select-keys '(1 2) [0])))
    (is (thrown? Throwable (select-keys 5 [:a])))))

;; --- merge reduces with conj, so a 2-vector arg is added AS an entry ---
(deftest merge-conj-semantics
  (is (= {:a 9 :b 2} (merge {:a 1} {:b 2} {:a 9})))
  (is (= {:a 1 :b 2} (merge {:a 1} [:b 2])))
  (is (= {:a 1 :b 2} (merge {:a 1} (first {:b 2}))))
  (is (= {:a 1} (merge nil {:a 1})))
  (is (= {:a 1} (merge {:a 1} nil)))
  (is (nil? (merge))))
