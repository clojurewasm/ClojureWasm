;; Ported from clojure/test_clojure/volatiles.clj (upstream verbatim)

(ns clojure.test-clojure.volatiles
  (:use clojure.test))

(deftest volatile-basics
  (let [vol (volatile! "abc")]
    (is (volatile? vol))
    (is (= "abc" @vol))
    (is (= "def" (vreset! vol "def")))
    (is (= "def" @vol))))

(deftest volatile-vswap!
  (let [vol (volatile! 10)]
    (is (= 11 (vswap! vol inc)))
    (is (= 11 @vol)))
  (let [vol (volatile! 10)]
    (is (= 20 (vswap! vol + 10)))
    (is (= 20 @vol)))
  (let [vol (volatile! 10)]
    (is (= 25 (vswap! vol + 10 5)))
    (is (= 25 @vol))))

;; Run tests
(run-tests)
