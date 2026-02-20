;; CLJW-ADD: Property-based reader round-trip tests
;; Verifies: (= x (read-string (pr-str x))) for various data types

(ns clojure.test-clojure.reader-roundtrip
  (:require [clojure.test :refer [deftest is testing run-tests]]))

(defn roundtrip [x]
  (read-string (pr-str x)))

;; ========== primitives ==========

(deftest test-roundtrip-primitives
  (testing "nil"
    (is (= nil (roundtrip nil))))
  (testing "booleans"
    (is (= true (roundtrip true)))
    (is (= false (roundtrip false))))
  (testing "integers"
    (doseq [n [0 1 -1 42 -42 1000000 -1000000]]
      (is (= n (roundtrip n)))))
  (testing "floats"
    (doseq [n [0.0 1.0 -1.0 3.14 -3.14]]
      (is (= n (roundtrip n)))))
  (testing "strings"
    (doseq [s ["" "hello" "hello world" "line1\nline2" "tab\there"
               "quote\"inside" "backslash\\\\" "unicode: \\u00e9"]]
      (is (= s (roundtrip s)))))
  (testing "characters"
    (doseq [c [\a \z \A \Z \0 \9 \space \newline \tab \\]]
      (is (= c (roundtrip c)))))
  (testing "keywords"
    (doseq [k [:a :hello :foo/bar :a-b :a_b]]
      (is (= k (roundtrip k)))))
  (testing "symbols"
    (doseq [s ['a 'hello 'foo/bar 'a-b 'a_b '+]]
      (is (= s (roundtrip s))))))

;; ========== collections ==========

(deftest test-roundtrip-collections
  (testing "vectors"
    (doseq [v [[] [1] [1 2 3] [[1 2] [3 4]] [nil true false]
               [:a "b" 3 4.0]]]
      (is (= v (roundtrip v)))))
  (testing "lists"
    (doseq [l ['() '(1) '(1 2 3) '((1 2) (3 4))]]
      (is (= l (roundtrip l)))))
  (testing "maps"
    (doseq [m [{} {:a 1} {:a 1 :b 2}
               {:nested {:deep true}}]]
      (is (= m (roundtrip m)))))
  (testing "sets"
    (doseq [s [#{} #{1} #{1 2 3}]]
      (is (= s (roundtrip s))))))

;; ========== nested structures ==========

(deftest test-roundtrip-nested
  (testing "deeply nested"
    (is (= [[{:a [1 2 #{3}]}]]
           (roundtrip [[{:a [1 2 #{3}]}]]))))
  (testing "mixed types"
    (is (= {:nums [1 2 3]
            :strs ["a" "b"]
            :nested {:x nil :y true}}
           (roundtrip {:nums [1 2 3]
                       :strs ["a" "b"]
                       :nested {:x nil :y true}})))))

;; ========== special forms ==========

(deftest test-roundtrip-special
  (testing "quoted forms"
    (is (= '(quote x) (roundtrip '(quote x)))))
  (testing "regex"
    (let [p #"\d+"]
      (is (= (str p) (str (roundtrip p))))))
  (testing "ratios"
    (is (= 1/3 (roundtrip 1/3)))
    (is (= 22/7 (roundtrip 22/7)))))

;; ========== generated data ==========

(deftest test-roundtrip-generated
  (testing "range of integers"
    (doseq [n (range -50 51)]
      (is (= n (roundtrip n)))))
  (testing "generated vectors"
    (doseq [size (range 0 10)]
      (let [v (vec (range size))]
        (is (= v (roundtrip v))))))
  (testing "generated maps"
    (doseq [size (range 0 5)]
      (let [m (zipmap (map #(keyword (str "k" %)) (range size))
                      (range size))]
        (is (= m (roundtrip m))))))
  (testing "generated nested"
    (let [data (reduce (fn [acc i]
                         (assoc acc (keyword (str "level" i))
                                {:val i :prev acc}))
                       {}
                       (range 5))]
      (is (= data (roundtrip data))))))

(run-tests)
