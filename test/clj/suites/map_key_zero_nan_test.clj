;; JVM oracle (clojure -M -e): signed zeros are = and hash to 0;
;; a literal repeated ##NaN is rejected, while NaN lookup is false.
(ns suites.map-key-zero-nan-test
  (:require [clojure.test :refer [deftest is]]))

(deftest signed-zero-keys
  (is (= 0.0 -0.0))
  (is (= 0 (hash 0.0) (hash -0.0)))
  (is (= 1 (count (hash-set 0.0 -0.0))))
  (is (= 1 (count (assoc {0.0 1} -0.0 2))))
  (is (= 2 (get (assoc {0.0 1} -0.0 2) 0.0)))
  ;; Nine integer keys force the hash-map path; the zero pair adds one key.
  (is (= 10 (count (assoc (into {} (map (fn [i] [i i]) (range 9))) 0.0 :a -0.0 :b))))
  (is (thrown? IllegalArgumentException (read-string "{0.0 1 -0.0 2}"))))

(deftest nan-keys
  ;; Values at runtime carry no reader-constant identity: distinct computed
  ;; NaNs must survive all constructor and collection paths.
  (let [a (/ 0.0 0.0) b (/ 0.0 0.0)]
    (is (= 2 (count (hash-set a b))))
    (is (= 2 (count (set [a b]))))
    (is (= 2 (count (into #{} [a b]))))
    (is (= 2 (count (hash-map a 1 b 2))))
    (is (= 2 (count (array-map a 1 b 2))))
    (is (= 2 (count (apply hash-map [a 1 b 2])))))
  (is (= 2 (count (assoc {##NaN 1} ##NaN 2))))
  (is (false? (contains? #{##NaN} ##NaN)))
  (is (thrown? IllegalArgumentException (read-string "{##NaN 1 ##NaN 2}")))
  (is (thrown? IllegalArgumentException (read-string "#{##NaN ##NaN}"))))
