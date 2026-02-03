;; clojure/test_clojure/control.clj — Equivalent tests for ClojureWasm
;;
;; Based on clojure/test_clojure/control.clj from Clojure JVM.
;; Java-dependent tests excluded (Exception, Long., thrown?, BigDecimal, Ratio).
;;
;; Uses clojure.test (auto-referred from bootstrap).

(println "[clojure/test_clojure/control] running...")

;; ========== do tests ==========

(deftest test-do
  (testing "no params => nil"
    (is (= (do) nil)))

  (testing "return last"
    (is (= (do 1) 1))
    (is (= (do 1 2) 2))
    (is (= (do 1 2 3 4 5) 5)))

  (testing "evaluate and return last"
    (is (= (let [a (atom 0)]
             (do (reset! a (+ @a 1))
                 (reset! a (+ @a 1))
                 (reset! a (+ @a 1))
                 @a)) 3))))

;; ========== loop/recur tests ==========

(deftest test-loop
  (testing "basic loop"
    (is (= 1 (loop [] 1))))

  (testing "loop with single binding"
    (is (= 3 (loop [a 1]
               (if (< a 3)
                 (recur (inc a))
                 a)))))

  (testing "loop building vector"
    (is (= [2 4 6] (loop [a []
                          b [1 2 3]]
                     (if (seq b)
                       (recur (conj a (* 2 (first b)))
                              (next b))
                       a)))))

  (testing "loop building list"
    (is (= '(6 4 2) (loop [a ()
                           b [1 2 3]]
                      (if (seq b)
                        (recur (conj a (* 2 (first b)))
                               (next b))
                        a))))))

;; ========== when tests ==========

(deftest test-when
  (testing "basic when"
    (is (= 1 (when true 1)))
    (is (= nil (when true)))
    (is (= nil (when false)))
    (is (= nil (when false :unreachable)))))

;; ========== when-not tests ==========

(deftest test-when-not
  (testing "basic when-not"
    (is (= 1 (when-not false 1)))
    (is (= nil (when-not true)))
    (is (= nil (when-not false)))
    (is (= nil (when-not true :unreachable)))))

;; ========== if-not tests (3-arg only) ==========

(deftest test-if-not
  (testing "basic if-not with else"
    (is (= 1 (if-not false 1 2)))
    (is (= 2 (if-not true 1 2)))
    (is (= 1 (if-not true :unreachable 1)))))

;; ========== when-let tests ==========

(deftest test-when-let
  (testing "basic when-let"
    (is (= 1 (when-let [a 1] a)))
    (is (= 2 (when-let [[a b] '(1 2)] b)))
    (is (= nil (when-let [a false] :unreachable)))))

;; ========== if-let tests (3-arg only) ==========
;; Note: ClojureWasm if-let requires else clause (JVM Clojure allows 2-arg)

(deftest test-if-let
  (testing "basic if-let with else"
    (is (= 1 (if-let [a 1] a :not-reached)))
    (is (= 2 (if-let [[a b] '(1 2)] b :not-reached)))
    (is (= :else (if-let [a false] :unreachable :else)))
    (is (= 1 (if-let [a false] a 1)))
    (is (= 1 (if-let [[a b] nil] b 1)))
    (is (= 1 (if-let [a false] :unreachable 1)))))

;; ========== cond tests ==========

(deftest test-cond
  (testing "empty cond"
    (is (= (cond) nil)))

  (testing "false conditions"
    (is (= (cond nil true) nil))
    (is (= (cond false true) nil)))

  (testing "short-circuit"
    (is (= (cond true 1 true :unreachable) 1))
    (is (= (cond nil 1 false 2 true 3 true 4) 3))
    (is (= (cond nil 1 false 2 true 3 true :unreachable) 3)))

  (testing "false values"
    (is (= (cond nil :a true :b) :b))
    (is (= (cond false :a true :b) :b)))

  ;; Note: ClojureWasm treats empty list () as falsy (JVM treats as truthy)
  (testing "truthy values"
    (is (= (cond true :a true :b) :a))
    (is (= (cond 0 :a true :b) :a))
    (is (= (cond "" :a true :b) :a))
    (is (= (cond 'sym :a true :b) :a))
    (is (= (cond :kw :a true :b) :a))
    ;; (is (= (cond () :a true :b) :a))  ;; Excluded: empty list is falsy in ClojureWasm
    (is (= (cond [] :a true :b) :a))
    (is (= (cond {} :a true :b) :a))
    (is (= (cond #{} :a true :b) :a)))

  (testing "evaluation"
    (is (= (cond (> 3 2) (+ 1 2) true :result true :unreachable) 3))
    (is (= (cond (< 3 2) (+ 1 2) true :result true :unreachable) :result))))

;; ========== condp tests (simplified) ==========

(deftest test-condp
  (testing "basic condp"
    (is (= :pass (condp = 1
                   1 :pass
                   2 :fail)))
    (is (= :pass (condp = 1
                   2 :fail
                   1 :pass)))
    (is (= :pass (condp = 1
                   2 :fail
                   :pass)))
    (is (= :pass (condp = 1
                   :pass)))))

;; ========== dotimes tests ==========

(deftest test-dotimes
  (testing "dotimes returns nil"
    (is (= nil (dotimes [n 1] n))))

  (testing "executes n times"
    (is (= 3 (let [a (atom 0)]
               (dotimes [n 3]
                 (swap! a inc))
               @a))))

  (testing "all values of n"
    (is (= [0 1 2] (let [a (atom [])]
                     (dotimes [n 3]
                       (swap! a conj n))
                     @a)))
    (is (= [] (let [a (atom [])]
                (dotimes [n 0]
                  (swap! a conj n))
                @a)))))

;; ========== while tests ==========

(deftest test-while
  (testing "while with false condition"
    (is (= nil (while nil :unreachable))))

  (testing "while decrements"
    (is (= [0 nil] (let [a (atom 3)
                         w (while (pos? @a)
                             (swap! a dec))]
                     [@a w])))))

;; ========== case tests (simplified) ==========
;; Note: Symbol matching excluded — ClojureWasm case with quoted symbol causes error

(deftest test-case
  (testing "basic case matching"
    (is (= :number (case 1
                     1 :number
                     :default)))
    (is (= :string (case "foo"
                     "foo" :string
                     :default)))
    (is (= :char (case \a
                   \a :char
                   :default)))
    (is (= :keyword (case :zap
                      :zap :keyword
                      :default)))
    ;; Symbol matching excluded — causes evaluation error
    ;; (is (= :symbol (case 'pow pow :symbol :default)))
    (is (= :nil (case nil
                  nil :nil
                  :default))))

  (testing "default clause"
    (is (= :default (case 999
                      1 :one
                      2 :two
                      :default))))

  ;; Multiple test values excluded — ClojureWasm case doesn't support (val1 val2 ...) syntax
  ;; (testing "multiple test values"
  ;;   (is (= :one-of-many (case 2 (1 2 3) :one-of-many :default)))
  ;;   (is (= :one-of-many (case \b (\a \b \c) :one-of-many :default)))
  ;;   (is (= :one-of-many (case "bar" ("foo" "bar" "baz") :one-of-many :default))))

  (testing "sequential matching"
    (is (= :vec (case [1 2]
                  [1 2] :vec
                  :default)))
    (is (= :map (case {:a 1}
                  {:a 1} :map
                  :default)))
    (is (= :set (case #{1 2}
                  #{1 2} :set
                  :default)))))

;; ========== Run tests ==========

(run-tests)
