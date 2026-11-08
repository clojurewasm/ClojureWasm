;; PersistentHashMap HAMT body (D-045 cycle A + cycle B).
;;
;; A map with more than 8 entries promotes ArrayMap -> HamtMap, so build
;; (assoc/into) and read (get/contains?) must keep working through the trie.
;; Covers string keys matched by bytes (D-151), int keys, interned keyword
;; keys, literal promotion, assoc replace-vs-insert on a .hash_map, and
;; contains? disambiguating a nil VALUE from an absent key. Sets ride the same
;; map HAMT transitively.
;;
;; Migrated from test/e2e/phase14_hamt_map.sh; each assertion keeps its bash
;; case name. The script rebuilt the same map inline in every one of its 30
;; invocations because each was a separate process; here the builders are
;; bound once per deftest, which is the only intentional shape change.
(ns suites.hamt-map-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string :as str]))

(defn- str-map [n] (into {} (map (fn [i] [(str i) i]) (range n))))
(defn- int-map [n] (into {} (map (fn [i] [i i]) (range n))))

;; --- promotion past 8 entries, across key types ---
(deftest string-keys-through-the-trie
  (let [m (str-map 20)]
    (is (= 5 (get m "5")))                        ; str20_get
    (is (= 20 (count m)))                         ; str20_cnt
    (is (nil? (get m "99")))))                    ; str20_miss

(deftest int-and-keyword-keys-through-the-trie
  (let [m (into {} (map (fn [i] [i (* i i)]) (range 50)))]
    (is (= 50 (count m)))                         ; int50_cnt
    (is (= 49 (get m 7))))                        ; int50_get
  (let [m (into {} (map (fn [i] [(keyword (str "k" i)) i]) (range 30)))]
    (is (= 15 (get m :k15)))))                    ; kw30_get

(deftest contains?-on-a-promoted-map
  (let [m (str-map 20)]
    (is (true? (contains? m "13")))               ; cont_t
    (is (false? (contains? m "x")))))             ; cont_f

(deftest map-literal-past-eight-keys-promotes
  (let [m {:a 1 :b 2 :c 3 :d 4 :e 5 :f 6 :g 7 :h 8 :i 9 :j 10}]
    (is (= 10 (count m)))                         ; lit_cnt
    (is (= 9 (get m :i)))))                       ; lit_get

(deftest assoc-replaces-or-inserts
  (let [m (int-map 12)]
    (testing "replace keeps the count"
      (is (= :x (get (assoc m 3 :x) 3)))          ; assoc_repl
      (is (= 12 (count (assoc m 3 :x)))))         ; assoc_repl_cnt
    (testing "insert grows it"
      (is (= 13 (count (assoc m 100 :new)))))))   ; assoc_ins_cnt

(deftest contains?-distinguishes-a-nil-value-from-an-absent-key
  (let [m (assoc (int-map 10) :k nil)]
    (is (nil? (get m :k)))                        ; nil_val_get
    (is (true? (contains? m :k)))))               ; nil_val_cont

;; --- cycle B: keys / vals / seq / dissoc / print / equality ---
(deftest keys-and-vals
  (is (= 20 (count (keys (int-map 20)))))                    ; keys_cnt
  (is (= 66 (apply + (vals (int-map 12)))))                  ; vals_sum
  (is (true? (= (set (keys (int-map 12))) (set (range 12)))))) ; keys_set

(deftest promoted-maps-compare-by-value
  (is (true? (= (int-map 20) (int-map 20))))      ; map_eq
  (is (false? (= (int-map 20) (int-map 19)))))    ; map_neq

(deftest dissoc-on-a-promoted-map
  (let [m (int-map 20)]
    (is (= 19 (count (dissoc m 5))))              ; dissoc_cnt
    (is (nil? (get (dissoc m 5) 5)))              ; dissoc_get
    (is (= 7 (get (dissoc m 5) 7)))               ; dissoc_oth
    (testing "dissoc of an absent key is a no-op"
      (is (= 20 (count (dissoc m 999)))))))       ; dissoc_abs

;; print is no longer silently empty — 12 entries => 11 commas => 12 splits
(deftest a-promoted-map-prints-its-entries
  (is (= 12 (count (str/split (str (int-map 12)) #",")))))   ; map_print

;; --- sets ride the same HAMT ---
(deftest sets-past-eight-elements
  (is (= 20 (count (into #{} (range 20)))))            ; set_cnt
  (is (true? (contains? (into #{} (range 20)) 13)))    ; set_cont
  (is (= 19 (count (disj (into #{} (range 20)) 5))))   ; set_disj
  (is (= 66 (apply + (into #{} (range 12)))))          ; set_seqsum
  (is (true? (= (into #{} (range 20)) (into #{} (range 20))))))  ; set_eq
