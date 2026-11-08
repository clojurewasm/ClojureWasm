;; Persistent collections as map keys / set members, compared and hashed BY
;; VALUE (D-092).
;;
;; Extends the vector-key fix to every persistent collection: a map, set or
;; list used as a key must find its structurally-equal twin, sets must dedup
;; them, and a vector must match an equal list across types. `(hash coll)` is
;; content-based (core.hashFn delegates to equal.valueHash), which is what
;; makes all of the above work through the HAMT.
;;
;; Migrated from test/e2e/phase14_collection_keys.sh; each assertion keeps its
;; bash case name.
(ns suites.collection-keys-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.set :as set]))

(deftest a-map-works-as-a-key
  (is (= :found (get {{:a 1} :found} {:a 1})))              ; map_get
  (is (true? (contains? {{:a 1} 0} {:a 1})))                ; map_contains
  (testing "so two equal map keys are ONE entry"
    (is (= 1 (count (assoc {} {:k 1} :x {:k 1} :y))))       ; map_assoc
    (is (= :y (get (assoc {} {:k 1} :x {:k 1} :y) {:k 1}))))) ; map_assoc_v

(deftest sets-and-lists-work-as-keys
  (is (= :s (get {#{1 2} :s} #{2 1})))                      ; set_get
  (is (= 1 (count (set [#{1 2} #{2 1}]))))                  ; set_dedup
  (is (= :l (get {'(1 2) :l} '(1 2)))))                     ; list_get

(deftest a-vector-and-an-equal-list-are-the-same-key
  (is (= :v (get {[1 2] :v} '(1 2))))                       ; cross_vl
  (is (= :l (get {'(1 2) :l} [1 2]))))                      ; cross_lv

(deftest the-library-functions-that-key-on-values
  (is (= 2 (get (frequencies [{:a 1} {:a 1} {:b 2}]) {:a 1})))   ; freq
  (is (= 2 (count (set [{:a 1} {:a 1} {:a 2}]))))               ; set_of_maps
  (is (= 2 (count (distinct [{:a 1} {:a 1} {:b 2}]))))          ; distinct
  (is (= 10 (get (zipmap [{:a 1} {:b 2}] [10 20]) {:a 1})))     ; zipmap
  (is (= 2 (count (set/index #{{:a 1 :b 1} {:a 1 :b 2} {:a 2 :b 3}} [:a])))) ; index
  (is (= 1 (count (set/join #{{:a 1 :b 2}} #{{:a 1 :c 3}})))))  ; join

;; hash is content-based, and order-independent for the unordered collections
(deftest hash-is-by-value
  (is (true? (= (hash {:a 1 :b 2}) (hash {:b 2 :a 1}))))    ; hash_map
  (is (true? (= (hash #{1 2}) (hash #{2 1}))))              ; hash_set
  (testing "and agrees across sequential types"
    (is (true? (= (hash [1 2]) (hash '(1 2)))))))           ; hash_vl

(deftest it-holds-through-nesting-and-promotion
  (is (= :deep (get {{:m {:k 1}} :deep} {:m {:k 1}})))      ; nested
  (testing "and past the ArrayMap -> HamtMap promotion"
    (is (= 7 (get (into {} (map (fn [i] [{:i i} i]) (range 20))) {:i 7}))))) ; hamt
