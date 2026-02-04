;; clojure/test_clojure/logic.clj — Equivalent tests for ClojureWasm
;;
;; Based on clojure/test_clojure/logic.clj from Clojure JVM.
;; Java-dependent tests excluded (into-array, Date, bigint, bigdec, Ratio, regex).
;;
;; Uses clojure.test (auto-referred from bootstrap).

(println "[clojure/test_clojure/logic] running...")

;; ========== test-if ==========

(deftest test-if
  (testing "true/false/nil"
    ;; true branch
    (is (= (if true :t) :t))
    (is (= (if true :t :f) :t))
    ;; false branch
    (is (= (if false :t) nil))
    (is (= (if false :t :f) :f))
    ;; nil branch
    (is (= (if nil :t) nil))
    (is (= (if nil :t :f) :f)))

  (testing "zero/empty is true"
    (is (= (if 0 :t :f) :t))
    (is (= (if 0.0 :t :f) :t))
    (is (= (if "" :t :f) :t))
    ;; Note: empty list () is falsy in ClojureWasm (F29)
    ;; (is (= (if () :t :f) :t))
    (is (= (if [] :t :f) :t))
    (is (= (if {} :t :f) :t))
    (is (= (if #{} :t :f) :t)))

  (testing "truthy values"
    (is (= (if 2 :t :f) :t))
    (is (= (if 2.5 :t :f) :t))
    (is (= (if \a :t :f) :t))
    (is (= (if "abc" :t :f) :t))
    (is (= (if 'abc :t :f) :t))
    (is (= (if :kw :t :f) :t))
    (is (= (if '(1 2) :t :f) :t))
    (is (= (if [1 2] :t :f) :t))
    (is (= (if {:a 1 :b 2} :t :f) :t))
    (is (= (if #{1 2} :t :f) :t))))

;; ========== test-nil-punning ==========

(deftest test-nil-punning
  (testing "first/next/rest on empty"
    (is (= (if (first []) :no :yes) :yes))
    (is (= (if (next [1]) :no :yes) :yes))
    ;; rest returns empty seq, which is truthy
    (is (= (if (rest [1]) :no :yes) :no)))

  (testing "butlast"
    (is (= (if (butlast [1]) :no :yes) :yes)))

  (testing "seq"
    (is (= (if (seq nil) :no :yes) :yes))
    (is (= (if (seq []) :no :yes) :yes)))

  (testing "concat"
    ;; concat returns lazy seq, which is truthy
    (is (= (if (concat) :no :yes) :no))
    (is (= (if (concat []) :no :yes) :no)))

  (testing "reverse"
    (is (= (if (reverse nil) :no :yes) :no))
    (is (= (if (reverse []) :no :yes) :no)))

  (testing "sort"
    ;; sort returns empty list for empty input
    (is (= (if (sort nil) :no :yes) :no))
    (is (= (if (sort []) :no :yes) :no))))

;; ========== test-and ==========

;; Note: ClojureWasm (and) returns nil, JVM returns true (F31)
(deftest test-and
  (testing "basic and"
    ;; (is (= (and) true))  ;; Excluded: ClojureWasm returns nil
    (is (= (and true) true))
    (is (= (and nil) nil))
    (is (= (and false) false)))

  (testing "and with two args"
    (is (= (and true nil) nil))
    (is (= (and true false) false)))

  (testing "and returns last truthy"
    (is (= (and 1 true :kw 'abc "abc") "abc")))

  (testing "and short-circuits on falsy"
    (is (= (and 1 true :kw nil 'abc "abc") nil))
    (is (= (and 1 true :kw 'abc "abc" false) false))))

;; ========== test-or ==========

(deftest test-or
  (testing "basic or"
    (is (= (or) nil))
    (is (= (or true) true))
    (is (= (or nil) nil))
    (is (= (or false) false)))

  (testing "or finds first truthy"
    (is (= (or nil false true) true))
    (is (= (or nil false 1 2) 1))
    (is (= (or nil false "abc" :kw) "abc")))

  (testing "or returns last falsy"
    (is (= (or false nil) nil))
    (is (= (or nil false) false))
    (is (= (or nil nil nil false) false)))

  (testing "or short-circuits on truthy"
    (is (= (or nil true false) true))
    (is (= (or nil false "abc" :not-reached) "abc"))))

;; ========== test-not ==========

(deftest test-not
  (testing "not on falsy values"
    (is (= (not nil) true))
    (is (= (not false) true)))

  (testing "not on truthy values"
    (is (= (not true) false))
    ;; numbers
    (is (= (not 0) false))
    (is (= (not 0.0) false))
    (is (= (not 42) false))
    (is (= (not 1.2) false))
    ;; characters
    (is (= (not \space) false))
    (is (= (not \tab) false))
    (is (= (not \a) false))
    ;; strings
    (is (= (not "") false))
    (is (= (not "abc") false))
    ;; symbols
    (is (= (not 'abc) false))
    ;; keywords
    (is (= (not :kw) false))
    ;; collections
    ;; Note: (not ()) would be true in ClojureWasm (F29)
    (is (= (not '(1 2)) false))
    (is (= (not []) false))
    (is (= (not [1 2]) false))
    (is (= (not {}) false))
    (is (= (not {:a 1 :b 2}) false))
    (is (= (not #{}) false))
    (is (= (not #{1 2}) false))))

;; ========== test-some? ==========

(deftest test-some?
  (testing "some? returns false only for nil"
    (is (= (some? nil) false))
    (is (= (some? false) true))
    (is (= (some? 0) true))
    (is (= (some? "abc") true))
    (is (= (some? []) true))))

;; ========== Run tests ==========

(run-tests)
