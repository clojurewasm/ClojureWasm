;; Upstream: clojure/test/clojure/test_clojure/clojure_zip.clj
;; Upstream lines: 49
;; CLJW markers: 1
;; CLJW-ADD: upstream file has no tests, these are CW-original

(ns clojure.test-clojure.clojure-zip
  (:use clojure.test)
  (:require [clojure.zip :as z]))

;; === Basic construction ===

(deftest test-vector-zip
  (let [vz (z/vector-zip [1 [2 3] 4])]
    (is (= [1 [2 3] 4] (z/node vz)))
    (is (z/branch? vz))
    (is (= [1 [2 3] 4] (z/children vz)))))

(deftest test-seq-zip
  (let [sz (z/seq-zip '(1 (2 3) 4))]
    (is (= '(1 (2 3) 4) (z/node sz)))
    (is (z/branch? sz))
    (is (= '(1 (2 3) 4) (z/children sz)))))

;; === Navigation ===

(deftest test-down-and-right
  (let [vz (z/vector-zip [1 [2 3] 4])]
    (is (= 1 (-> vz z/down z/node)))
    (is (= [2 3] (-> vz z/down z/right z/node)))
    (is (= 4 (-> vz z/down z/right z/right z/node)))))

(deftest test-up
  (let [vz (z/vector-zip [1 [2 3] 4])]
    (is (= [1 [2 3] 4] (-> vz z/down z/up z/node)))
    (is (= [1 [2 3] 4] (-> vz z/down z/right z/up z/node)))))

(deftest test-left
  (let [vz (z/vector-zip [1 2 3])]
    (is (= 2 (-> vz z/down z/right z/node)))
    (is (= 1 (-> vz z/down z/right z/left z/node)))))

(deftest test-leftmost-rightmost
  (let [vz (z/vector-zip [1 2 3])]
    (is (= 1 (-> vz z/down z/right z/right z/leftmost z/node)))
    (is (= 3 (-> vz z/down z/rightmost z/node)))))

(deftest test-path
  (let [vz (z/vector-zip [1 [2 3] 4])]
    (is (nil? (z/path vz)))
    (is (= [[1 [2 3] 4]] (z/path (z/down vz))))
    (is (= [[1 [2 3] 4] [2 3]] (-> vz z/down z/right z/down z/path)))))

(deftest test-lefts-rights
  (let [vz (z/vector-zip [1 2 3])]
    (is (nil? (z/lefts (z/down vz))))
    (is (= '(1) (-> vz z/down z/right z/lefts)))
    (is (= '(2 3) (z/rights (z/down vz))))
    (is (= '(3) (-> vz z/down z/right z/rights)))))

;; === Modification ===

(deftest test-replace
  (let [vz (z/vector-zip [1 2 3])]
    (is (= [99 2 3] (-> vz z/down (z/replace 99) z/root)))))

(deftest test-edit
  (let [vz (z/vector-zip [1 2 3])]
    (is (= [10 2 3] (-> vz z/down (z/edit * 10) z/root)))))

(deftest test-insert-left-right
  (let [vz (z/vector-zip [1 3])]
    (is (= [1 2 3] (-> vz z/down z/right (z/insert-left 2) z/root)))
    (is (= [1 3 4] (-> vz z/down z/right (z/insert-right 4) z/root)))))

(deftest test-insert-child-append-child
  (let [vz (z/vector-zip [1 [2] 3])]
    (is (= [1 [0 2] 3] (-> vz z/down z/right (z/insert-child 0) z/root)))
    (is (= [1 [2 9] 3] (-> vz z/down z/right (z/append-child 9) z/root)))))

(deftest test-remove
  (let [vz (z/vector-zip [1 2 3])]
    (is (= [1 3] (-> vz z/down z/right z/remove z/root)))))

;; === Traversal ===

(deftest test-next-end
  (let [vz (z/vector-zip [1 [2] 3])]
    (is (= 1 (-> vz z/next z/node)))
    (is (= [2] (-> vz z/next z/next z/node)))
    (is (= 2 (-> vz z/next z/next z/next z/node)))
    (is (= 3 (-> vz z/next z/next z/next z/next z/node)))
    (is (z/end? (-> vz z/next z/next z/next z/next z/next)))))

(deftest test-prev
  (let [vz (z/vector-zip [1 [2] 3])]
    (is (= 2 (-> vz z/next z/next z/next z/node)))
    (is (= [2] (-> vz z/next z/next z/next z/prev z/node)))))

(deftest test-depth-first-walk
  (let [data [1 [2 3] 4]
        vz (z/vector-zip data)]
    (is (= [10 [20 30] 40]
           (loop [loc (z/next vz)]
             (if (z/end? loc)
               (z/root loc)
               (if (number? (z/node loc))
                 (recur (z/next (z/edit loc * 10)))
                 (recur (z/next loc)))))))))

;; === Root ===

(deftest test-root
  (let [vz (z/vector-zip [1 [2 3] 4])]
    (is (= [1 [2 3] 4] (z/root vz)))
    (is (= [1 [2 3] 4] (-> vz z/down z/right z/down z/root)))))

(run-tests)
