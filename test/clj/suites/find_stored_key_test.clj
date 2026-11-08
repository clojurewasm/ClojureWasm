;; JVM oracle (clojure -M -e, 1.12): find / select-keys / a set's get and
;; invoke answer the key or element STORED in the collection (clj
;; Associative.entryAt, PersistentHashSet.get), not the `=` probe. A transient
;; map's find is the exception: ATransientMap.entryAt builds its entry from the
;; probe, so there the probe is clj's own answer.
(ns suites.find-stored-key-test
  (:require [clojure.test :refer [deftest is]]))

(def ^:private big-map
  ;; More than 8 entries: the hash-map (HAMT) path, not the array map.
  (into {1N :a} (map (fn [i] [(+ 100 i) i]) (range 10))))

(def ^:private big-set (into #{1N} (range 100 110)))

(defn- exact [x] [x (class x)])

(deftest find-answers-stored-key
  (is (= [0.0 :z] (find {0.0 :z} -0.0)))
  (is (= 0.0 (key (find {0.0 :z} -0.0))))
  (is (= "0.0" (pr-str (key (find {0.0 :z} -0.0)))))
  (is (= (exact 1N) (exact (key (find {1N :a} 1)))))
  (is (= (exact 1N) (exact (key (find big-map 1)))))
  (is (= "[0.0 :z]" (pr-str (find (assoc big-map 0.0 :z) -0.0))))
  (is (= (exact 1N) (exact (key (find (sorted-map 1N :a) 1)))))
  (is (= "[0.0 :z]" (pr-str (find (sorted-map 0.0 :z) -0.0))))
  (is (= (exact 1N) (exact (key (.entryAt {1N :a} 1)))))
  (is (map-entry? (find {1N :a} 1)))
  (is (nil? (find {1N :a} 2)))
  (is (nil? (find nil 1))))

(deftest find-keeps-probe-where-clj-does
  (is (= (exact 1) (exact (key (find (transient {1N :a}) 1)))))
  (is (= (exact 1) (exact (key (find (transient big-map) 1)))))
  (is (= [1 20] (find [10 20] 1))))

(deftest select-keys-carries-stored-key
  (is (= "{1N :a}" (pr-str (select-keys {1N :a} [1]))))
  (is (= "{1N :a}" (pr-str (select-keys big-map [1 -1]))))
  (is (= "{0.0 :z}" (pr-str (select-keys {0.0 :z} [-0.0]))))
  (is (= "{1N :a}" (pr-str (select-keys (sorted-map 1N :a) [1]))))
  (is (= {:a nil} (select-keys {:a nil} [:a]))))

(deftest set-get-and-invoke-answer-stored-element
  (is (= (exact 1N) (exact (get #{1N} 1))))
  (is (= (exact 1N) (exact (get #{1N} 1 :nf))))
  (is (= :nf (get #{} 1 :nf)))
  (is (= (exact 1N) (exact (#{1N} 1))))
  (is (= "0.0" (pr-str (#{0.0} -0.0))))
  (is (= "0.0" (pr-str (get #{0.0} -0.0))))
  (is (= (exact 1N) (exact (get big-set 1))))
  (is (= (exact 1N) (exact (big-set 1))))
  (is (= (exact 1N) (exact (get (sorted-set 1N) 1))))
  (is (= (exact 1N) (exact ((sorted-set 1N) 1))))
  (is (= "0.0" (pr-str ((sorted-set 0.0) -0.0))))
  (is (= :nf (get (sorted-set 1N) 2 :nf)))
  (is (= (exact 1N) (exact (get (transient #{1N}) 1))))
  (is (= (exact 1N) (exact ((transient #{1N}) 1))))
  (is (= "0.0" (pr-str ((transient #{0.0}) -0.0))))
  (is (= "0.0" (pr-str (get (transient #{0.0}) -0.0 :nf))))
  (is (= :k (:k #{:k}))))
