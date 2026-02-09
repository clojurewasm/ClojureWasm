;; Upstream: clojure/test/clojure/test_clojure/java_interop.clj (array sections)
;; Upstream lines: ~250 (array-related subset)
;; CLJW markers: 12

;; CLJW: Extracted array tests from java_interop.clj.
;; CLJW: Integer/TYPE → "int", Long → "Long" (CW has no Java class refs)
;; CLJW: Removed class checks, NegativeArraySizeException → ExceptionInfo
;; CLJW: Removed test-to-passed-array-for (java.util.Arrays dependency)
;; CLJW: Removed type compatibility checks in into-array (CW arrays are untyped)
;; CLJW: Added CW-specific tests for seq/first/rest/nth/count integration

(ns clojure.test-clojure.arrays
  (:use clojure.test))

;; CLJW: Adapted macro — no 2-arg or size+init-seq forms (CW typed arrays take 1 arg only)
(defmacro deftest-type-array [type-array-fn]
  `(deftest ~(symbol (str "test-" type-array-fn))
     ;; given size (empty)
     (are [x] (and (= (alength (~type-array-fn x)) x))
       0 1 5)

     ;; copy of a sequence
     (are [x] (and (= (alength (~type-array-fn x)) (count x))
                   (= (vec (~type-array-fn x)) x))
       []
       [1]
       [1 -2 3 0 5])))

(deftest-type-array int-array)
(deftest-type-array long-array)

;; CLJW: adapted — ExceptionInfo instead of NegativeArraySizeException
(deftest test-type-array-exceptions
  (are [x] (thrown? ExceptionInfo x)
    (int-array -1)
    (long-array -1)
    (float-array -1)
    (double-array -1)))

;; CLJW: adapted — type arg is string, removed class checks
(deftest test-make-array
  ;; negative size
  (is (thrown? ExceptionInfo (make-array "Integer" -1)))

  ;; one-dimensional
  (are [x] (= (alength (make-array "Integer" x)) x)
    0 1 5)

  (let [a (make-array "Long" 5)]
    (aset a 3 42)
    (are [x y] (= x y)
      (aget a 3) 42))

  ;; multi-dimensional
  (let [a (make-array "Long" 3 2 4)]
    (aset a 0 1 2 987)
    (are [x y] (= x y)
      (alength a) 3
      (alength (first a)) 2
      (alength (first (first a))) 4
      (aget a 0 1 2) 987)))

(deftest test-to-array
  (let [v [1 "abc" :kw \c []]
        a (to-array v)]
    (are [x y] (= x y)
      ;; length
      (alength a) (count v)
      ;; content
      (vec a) v))

  ;; different kinds of collections
  (are [x] (and (= (alength (to-array x)) (count x))
                (= (vec (to-array x)) (vec x)))
    ()
    '(1 2)
    []
    [1 2]
    (sorted-set)
    (sorted-set 1 2)

    (int-array 0)
    (int-array [1 2 3])

    (to-array [])
    (to-array [1 2 3])))

;; CLJW: adapted — removed type compatibility checks (CW arrays hold any Value)
(deftest test-into-array
  ;; simple case
  (let [v [1 2 3 4 5]
        a (into-array v)]
    (are [x y] (= x y)
      (alength a) (count v)
      (vec a) v))

  (is (= [nil 1 2] (vec (into-array [nil 1 2]))))

  ;; different kinds of collections
  (are [x] (and (= (alength (into-array x)) (count x))
                (= (vec (into-array x)) (vec x)))
    ()
    '(1 2)
    []
    [1 2]
    (sorted-set)
    (sorted-set 1 2)

    (int-array 0)
    (int-array [1 2 3])

    (to-array [])
    (to-array [1 2 3])))

(deftest test-to-array-2d
  ;; ragged array
  (let [v [[1] [2 3] [4 5 6]]
        a (to-array-2d v)]
    (are [x y] (= x y)
      (alength a) (count v)
      (alength (aget a 0)) (count (nth v 0))
      (alength (aget a 1)) (count (nth v 1))
      (alength (aget a 2)) (count (nth v 2))

      (vec (aget a 0)) (nth v 0)
      (vec (aget a 1)) (nth v 1)
      (vec (aget a 2)) (nth v 2)))

  ;; empty array
  (let [a (to-array-2d [])]
    (are [x y] (= x y)
      (alength a) 0
      (vec a) [])))

(deftest test-alength
  (are [x] (= (alength x) 0)
    (int-array 0)
    (long-array 0)
    (float-array 0)
    (double-array 0)
    (boolean-array 0)
    (byte-array 0)
    (char-array 0)
    (short-array 0)
    (make-array "Integer" 0)
    (to-array [])
    (into-array [])
    (to-array-2d []))

  (are [x] (= (alength x) 1)
    (int-array 1)
    (long-array 1)
    (float-array 1)
    (double-array 1)
    (boolean-array 1)
    (byte-array 1)
    (char-array 1)
    (short-array 1)
    (make-array "Integer" 1)
    (to-array [1])
    (into-array [1])
    (to-array-2d [[1]]))

  (are [x] (= (alength x) 3)
    (int-array 3)
    (long-array 3)
    (float-array 3)
    (double-array 3)
    (boolean-array 3)
    (byte-array 3)
    (char-array 3)
    (short-array 3)
    (make-array "Integer" 3)
    (to-array [1 "a" :k])
    (into-array [1 2 3])
    (to-array-2d [[1] [2 3] [4 5 6]])))

(deftest test-aclone
  ;; clone all arrays except 2D
  (are [x] (and (= (alength (aclone x)) (alength x))
                (= (vec (aclone x)) (vec x)))
    (int-array 0)
    (long-array 0)
    (float-array 0)
    (double-array 0)
    (boolean-array 0)
    (byte-array 0)
    (char-array 0)
    (short-array 0)
    (make-array "Integer" 0)
    (to-array [])
    (into-array [])

    (int-array [1 2 3])
    (long-array [1 2 3])
    (float-array [1 2 3])
    (double-array [1 2 3])
    (boolean-array [true false])
    (byte-array [1 2])
    (char-array [\a \b \c])
    (short-array [1 2])
    (make-array "Integer" 3)
    (to-array [1 "a" :k])
    (into-array [1 2 3]))

  ;; clone 2D
  (are [x] (and (= (alength (aclone x)) (alength x))
                (= (map alength (aclone x)) (map alength x))
                (= (map vec (aclone x)) (map vec x)))
    (to-array-2d [])
    (to-array-2d [[1] [2 3] [4 5 6]])))

;; CLJW-ADD: array macro tests
(deftest test-amap
  (let [arr (object-array [1 2 3])
        result (amap arr idx ret (* 2 (aget arr idx)))]
    (is (= (vec result) [2 4 6])))
  (let [arr (object-array [])
        result (amap arr idx ret (aget arr idx))]
    (is (= (vec result) []))))

(deftest test-areduce
  (let [arr (object-array [1 2 3 4 5])
        sum (areduce arr idx ret 0 (+ ret (aget arr idx)))]
    (is (= sum 15)))
  (let [arr (object-array [])
        sum (areduce arr idx ret 0 (+ ret (aget arr idx)))]
    (is (= sum 0))))

;; CLJW-ADD: seq integration tests
(deftest test-array-seq-integration
  ;; seq on array
  (is (= (seq (object-array [1 2 3])) '(1 2 3)))
  (is (nil? (seq (object-array []))))

  ;; first / rest
  (is (= (first (object-array [10 20 30])) 10))
  (is (nil? (first (object-array []))))
  (is (= (vec (rest (object-array [10 20 30]))) [20 30]))
  (is (= (vec (rest (object-array []))) []))

  ;; nth
  (is (= (nth (object-array [10 20 30]) 0) 10))
  (is (= (nth (object-array [10 20 30]) 2) 30))
  (is (= (nth (object-array [10 20 30]) 5 :not-found) :not-found))

  ;; count
  (is (= (count (object-array [])) 0))
  (is (= (count (object-array [1 2 3])) 3))

  ;; vec
  (is (= (vec (object-array [1 2 3])) [1 2 3]))
  (is (= (vec (object-array [])) []))

  ;; map over array (via seq)
  (is (= (map inc (object-array [1 2 3])) '(2 3 4)))

  ;; reduce over array (via seq)
  (is (= (reduce + (object-array [1 2 3 4 5])) 15)))

;; CLJW-ADD: bytes? predicate
(deftest test-bytes-pred
  (is (true? (bytes? (byte-array 3))))
  (is (false? (bytes? (int-array 3))))
  (is (false? (bytes? "hello")))
  (is (false? (bytes? nil))))

;; CLJW-ADD: aclone independence
(deftest test-aclone-independence
  (let [arr (object-array [10 20 30])
        clone (aclone arr)]
    (aset clone 0 99)
    (is (= (aget arr 0) 10))
    (is (= (aget clone 0) 99))))
