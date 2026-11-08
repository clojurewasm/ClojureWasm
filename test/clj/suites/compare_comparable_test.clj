;; JVM oracle (clojure -M -e, 1.12): `compare`, `sort` and sorted
;; collections accept the JVM-Comparable values clj accepts
;; (CLJW-COMPARE-COMPARABLE). java.util.Date orders by epoch-ms,
;; java.util.UUID as UUID.compareTo (signed msb, then signed lsb),
;; java.io.File by path String.compareTo, and a deftype/reify implementing
;; java.lang.Comparable through its compareTo. `compare` returns the
;; receiver's compareTo int unchanged, so on Files it is the path
;; difference, not its sign (CLJW-FILE-COMPARE-MAGNITUDE). Incomparable
;; pairs still raise ClassCastException.
(ns suites.compare-comparable-test
  (:require [clojure.test :refer [deftest is]]))

(deftest date-orders-by-time
  (let [d1 (java.util.Date. 1000)
        d2 (java.util.Date. 2000)]
    (is (= [-1 1 0] [(compare d1 d2) (compare d2 d1) (compare d1 (java.util.Date. 1000))]))
    (is (= [1000 2000] (mapv inst-ms (sort [d2 d1]))))
    (is (= [1000 2000] (mapv inst-ms (sorted-set d2 d1))))
    (is (= [1000 2000] (mapv inst-ms (keys (sorted-map d2 :b d1 :a)))))))

(def ^:private ua #uuid "00000000-0000-0000-0000-000000000001")
(def ^:private ub #uuid "80000000-0000-0000-0000-000000000000")
(def ^:private uc #uuid "7fffffff-ffff-ffff-ffff-ffffffffffff")
(def ^:private ud #uuid "00000000-0000-0000-8000-000000000000")

(deftest uuid-orders-by-signed-msb-then-lsb
  (is (= [ub ud ua uc] (sort [uc ub ua ud])))
  (is (= [1 -1 1 0] [(compare ua ub) (compare ub ua) (compare ua ud) (compare ua ua)]))
  (is (= [ub ua uc] (vec (sorted-set uc ub ua))))
  (is (= [ub ua uc] (sort-by identity [uc ub ua]))))

(deftype V [n]
  java.lang.Comparable
  (compareTo [_ o] (compare n (.-n ^V o)))
  Object
  (toString [_] (str "V" n)))

(deftest comparable-deftype-orders-itself
  (is (= ["V1" "V2" "V3"] (map str (sort [(V. 3) (V. 1) (V. 2)]))))
  (is (= -1 (compare (V. 1) (V. 2))))
  (is (= ["V1" "V3"] (map str (keys (sorted-map (V. 3) :c (V. 1) :a)))))
  (is (= ["V1" "V3"] (map str (sort-by identity [(V. 3) (V. 1)]))))
  (is (= ["V1" "V3"] (map str (sorted-set (V. 3) (V. 1)))))
  (is (= ["V1" "V2"] (map (comp str :k) (sort-by :k [{:k (V. 2)} {:k (V. 1)}])))))

(deftest file-orders-by-path-and-keeps-magnitude
  (let [a (java.io.File. "a")
        b (java.io.File. "b")
        c (java.io.File. "c")]
    (is (= -2 (compare a c)))
    (is (= 2 (compare c a)))
    (is (= 0 (compare a (java.io.File. "a"))))
    (is (= ["a" "b"] (mapv str (sort [b a]))))
    (is (= ["a" "b" "c"] (mapv str (sorted-set c a b))))))

(deftest incomparable-pairs-raise
  (let [d1 (java.util.Date. 1000)]
    (is (thrown? ClassCastException (compare d1 ua)))
    (is (thrown? ClassCastException (compare ua 1)))
    (is (thrown? ClassCastException (doall (sort [d1 "x"]))))
    (is (thrown? ClassCastException (sorted-set ua d1)))))
