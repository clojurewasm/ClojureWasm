;; test/e2e/phase14_arrays.sh
;;
;; ADR-0105 / D-287, ADR-0204 — Java arrays with an element kind: object
;; arrays hold Values, the typed constructors native elements (byte i8 ...
;; double f64). Constructors convert like clj (wrap, truncate), `aset` is
;; strict; identity equality; simple class name (AD-003); class arguments
;; are advisory (AD-019).

;; Migrated from test/e2e/phase14_arrays.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.arrays-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest arrays-cases
  (is (= ":x" (pr-str (let [a (object-array 3)] (aset a 1 :x) (aget a 1)))) "aset_aget")
  (is (= "4" (pr-str (alength (object-array 4)))) "alength")
  (is (= "[9 7]" (pr-str (let [a (int-array [7 7]) b (aclone a)] (aset a 0 9) [(aget a 0) (aget b 0)]))) "aclone_independent")
  (is (= "[nil nil]" (pr-str (vec (object-array 2)))) "object_array_nil")
  (is (= "[0 0]" (pr-str (vec (int-array 2)))) "int_array_zero")
  (is (= "[0.0 0.0]" (pr-str (vec (double-array 2)))) "double_array_zero")
  (is (= "[false false]" (pr-str (vec (boolean-array 2)))) "boolean_array_false")
  (is (= "[1 2 44]" (pr-str (vec (byte-array [1 2 300])))) "byte_array_wrap")
  (is (= "-56" (pr-str (let [a (byte-array 1)] (aset-byte a 0 -56) (aget a 0)))) "aset_byte")
  (is (= "[:a :b :c]" (pr-str (vec (object-array [:a :b :c])))) "object_array_from_seq")
  (is (= "[1 2 3]" (pr-str (vec (seq (int-array [1 2 3]))))) "seq_over_array")
  (is (= "3" (pr-str (count (int-array [1 2 3])))) "count_array")
  (is (= "[2 3 4]" (pr-str (vec (map inc (int-array [1 2 3]))))) "map_over_array")
  (is (= "6" (pr-str (reduce + (int-array [1 2 3])))) "reduce_over_array")
  (is (= ":b" (pr-str (nth (object-array [:a :b]) 1))) "nth_array")
  (is (= ":none" (pr-str (nth (object-array [:a]) 9 :none))) "nth_array_default")
  (is (= "5" (pr-str (alength (make-array nil 5)))) "make_array_1d")
  (is (= "[2 3]" (pr-str (let [m (make-array nil 2 3)] [(alength m) (alength (aget m 0))]))) "make_array_2d")
  (is (= "[2 4 6]" (pr-str (vec (amap (int-array [1 2 3]) i r (* 2 (aget r i)))))) "amap")
  (is (= "6" (pr-str (areduce (int-array [1 2 3]) i r 0 (+ r (aget (int-array [1 2 3]) i))))) "areduce")
  (is (= "[1 2 3]" (pr-str (vec (to-array [1 2 3])))) "to_array")
  (is (= "[4 5]" (pr-str (vec (into-array [4 5])))) "into_array")
  (is (= "false" (pr-str (= (object-array 1) (object-array 1)))) "array_identity_neq")
  (is (= "true" (pr-str (let [a (object-array 1)] (= a a)))) "array_self_eq")
  (is (= "true" (pr-str (array? (object-array 0)))) "array_pred")
  (is (= "false" (pr-str (array? [1 2]))) "array_pred_neg")
  (is (= "array" (pr-str (class (object-array 0)))) "array_class_simple")
  (is (= "65" (pr-str (let [^"[B" b (byte-array 1)] (aset b 0 65) (aget b 0)))) "type_hint_advisory"))

(defn- thrown-msg [thunk]
  (try (thunk) nil (catch Exception e (ex-message e))))

(deftest typed-array-values
  (testing "constructors convert each element to the kind (clj RT.xArray)"
    (is (= [1 2 44] (vec (byte-array [1 2 300]))))
    (is (= [1 -2] (vec (long-array [1.9 -2.7]))))
    (is (= [1.0 2.0] (vec (double-array [1 2]))))
    (is (= [1 -32768] (vec (short-array [1 32768]))))
    (is (= [true false true] (vec (boolean-array [1 nil :x]))))
    (is (= [\A \b] (vec (char-array [65 \b])))))
  (testing "a long keeps all 64 bits"
    (is (= [Long/MAX_VALUE Long/MIN_VALUE] (vec (long-array [Long/MAX_VALUE Long/MIN_VALUE]))))
    (is (= Long/MAX_VALUE (aget (long-array [Long/MAX_VALUE]) 0)))
    (is (= (list Long/MAX_VALUE 1) (seq (long-array [Long/MAX_VALUE 1]))))
    (is (= "(9223372036854775807 1)" (pr-str (seq (long-array [Long/MAX_VALUE 1]))))))
  (testing "a float array stores single precision"
    (is (= [1.1 1.6777216E7] (vec (float-array [1.1 16777217])))))
  (testing "fresh slots hold the kind's default"
    (is (= [0 0] (vec (long-array 2))))
    (is (= [nil] (vec (object-array 1))))
    (is (= 0 (int (aget (char-array 1) 0)))))
  (testing "the 2-arg forms fill or copy"
    (is (= [7 7 7] (vec (long-array 3 7))))
    (is (= [1 2 0] (vec (int-array 3 [1 2]))))
    (is (= [1] (vec (int-array 1 [1 2 3])))))
  (testing "aclone keeps the kind"
    (is (bytes? (aclone (byte-array 2))))))

(deftest aset-is-strict
  (is (re-find #"in range for a byte array" (thrown-msg #(aset (byte-array 1) 0 200))))
  (is (re-find #"integer" (thrown-msg #(aset (long-array 1) 0 1.5))))
  (is (re-find #"integer" (thrown-msg #(aset (int-array 1) 0 nil))))
  (is (re-find #"boolean" (thrown-msg #(aset (boolean-array 1) 0 1))))
  (is (re-find #"char" (thrown-msg #(aset (char-array 1) 0 65))))
  (is (some? (thrown-msg #(aset-byte (byte-array 1) 0 200))) "aset-byte range-checks as clj")
  (is (= 2.0 (let [a (double-array 1)] (aset a 0 2) (aget a 0))) "an integer widens into a double")
  (is (= :k (let [a (object-array 1)] (aset a 0 :k) (aget a 0)))))

(deftest kind-predicates-and-host-statics
  (is (bytes? (byte-array 1)))
  (is (not (bytes? (int-array 1))))
  (is (not (bytes? (object-array 1))))
  (is (not (bytes? [1])))
  (is (java.util.Arrays/equals (double-array [1]) (double-array [1.0])))
  (is (not (java.util.Arrays/equals (int-array [1]) (long-array [1]))))
  (is (= [-0.0 0.0 1.0 3.0 :nan]
         (map #(if (Double/isNaN %) :nan %)
              (let [a (double-array [3 ##NaN 0.0 -0.0 1])] (java.util.Arrays/sort a) (vec a)))))
  (is (= [1 2 3] (let [a (int-array [3 1 2])] (java.util.Arrays/sort a) (vec a))))
  (is (= [5 0 0] (vec (java.util.Arrays/copyOf (long-array [5]) 3))))
  (is (= [9 9] (let [a (long-array 2)] (java.util.Arrays/fill a 9) (vec a))))
  (is (= [1 1 2] (let [a (long-array [1 2 3])] (System/arraycopy a 0 a 1 2) (vec a))))
  (is (some? (thrown-msg #(System/arraycopy (long-array 1) 0 (int-array 1) 0 1))))
  (is (= "hi" (String. (byte-array [104 105]))))
  (is (= "hi" (String. (char-array [\h \i]))))
  (is (some? (thrown-msg #(String. (int-array [104 105])))))
  (is (bytes? (.getBytes "abc"))))

