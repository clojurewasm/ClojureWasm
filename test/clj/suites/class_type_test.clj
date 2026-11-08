;; (class x) / (type x) + the numeric-tower constructors they classify
;; (ADR-0059, D-191, D-194, D-215, D-337 / AD-044).
;;
;; Migrated from test/e2e/phase14_class_type.sh: the bash tier spawned one
;; `cljw -e` per case and compared stdout, so every "prints X" assertion
;; becomes `(= "X" (pr-str expr))` here — pr-str, not `=` on the value,
;; because the printed form is what the bash actually pinned (e.g. `100N`
;; vs `100`, which are `=` to each other).
;;
;; Run by `test/clj/run_suites.clj` — one cljw process for the whole file.
(ns suites.class-type-test
  (:require [clojure.test :refer [deftest is testing]]))

(defrecord Point [x y])

(defmulti mm identity)

;; --- native class names print as simple names (ADR-0059) ---
(deftest class-simple-names
  (testing "native classes"
    (is (= "Long" (pr-str (class 5))))
    (is (= "String" (pr-str (class "x"))))
    (is (= "PersistentVector" (pr-str (class []))))
    (is (= "Keyword" (pr-str (class :a)))))
  (testing "(class nil) is nil, as on the JVM"
    (is (nil? (class nil))))
  (testing "numeric-tower classes"
    (is (= "BigInt" (pr-str (class (bigint 5)))))
    (is (= "Ratio" (pr-str (class 1/2))))
    (is (= "BigDecimal" (pr-str (class 1.5M))))))

;; --- interning: the same class is `=`, and usable as a map key ---
(deftest class-interning
  (is (= true (= (class 5) (class 6))))
  (is (= false (= (class 5) (class "x"))))
  (testing "class as a map key (group-by class)"
    (is (= [1 2] (get (group-by class [1 2 "a" "b"]) (class 1))))))

;; --- (type x) = (or (:type (meta x)) (class x)) ---
(deftest type-fn
  (is (= "Long" (pr-str (type 5))))
  (is (= :foo (type (with-meta [1 2] {:type :foo})))))

;; --- a user record's class prints its name + equals its name Var ---
(deftest user-record-class
  (is (= "Point" (pr-str (class (->Point 1 2)))))
  (is (= true (= (class (->Point 1 2)) Point))))

;; --- (bigint x): BigInt passthrough, else truncate toward zero ---
(deftest bigint-ctor
  (testing "integers and floats"
    (is (= "100N" (pr-str (bigint 100))))
    (is (= "3N" (pr-str (bigint 3.9))))
    (is (= "-3N" (pr-str (bigint -3.9))))
    (is (= "0N" (pr-str (bigint 1/2)))))
  (testing "strings — arbitrary precision via parseBase10 (D-191 / D-047)"
    (is (= "100N" (pr-str (bigint "100"))))
    (is (= "-5N" (pr-str (bigint "-5"))))
    ;; 2^65 — the exact value D-047 documented as setString-broken on Linux.
    (is (= "36893488147419103232N" (pr-str (bigint "36893488147419103232")))))
  (testing "large floats — bigdec(d).toBigInteger() truncation"
    (is (= "1000000000000000000000000000000N" (pr-str (bigint 1e30))))
    (is (= "-100000000000000000000N" (pr-str (bigint -1e20))))))

;; --- (bigdec x): int/BigInt→scale0, BigDecimal passthrough, float via toString ---
(deftest bigdec-ctor
  (testing "numbers"
    (is (= "100M" (pr-str (bigdec 100))))
    (is (= "1.5M" (pr-str (bigdec 1.5))))
    (is (= "0.25M" (pr-str (bigdec 0.25))))
    (is (= "100.0M" (pr-str (bigdec 100.0))))
    (is (= "5M" (pr-str (bigdec (bigint 5)))))
    (is (= "1.5M" (pr-str (bigdec 1.5M)))))
  (testing "strings — scale taken from the decimal point (D-191)"
    (is (= "1.50M" (pr-str (bigdec "1.50"))))
    (is (= "100M" (pr-str (bigdec "100"))))
    (is (= "-3.14M" (pr-str (bigdec "-3.14")))))
  (testing "ratios — exact when d = 2^a*5^b, else ArithmeticException (D-191)"
    (is (= "0.25M" (pr-str (bigdec 1/4))))
    (is (= "0.35M" (pr-str (bigdec 7/20))))
    (is (= "-0.25M" (pr-str (bigdec -1/4))))
    (is (thrown? Throwable (bigdec 1/3))))
  (testing "scientific notation (JVM BigDecimal.toString)"
    (is (= "1.0E+30M" (pr-str (bigdec 1e30))))
    (is (= "1.5E+2M" (pr-str (bigdec "1.5E2"))))
    (is (= "1.0E-10M" (pr-str (bigdec 1e-10))))
    (is (= "0.000010M" (pr-str (bigdec 1e-5))))))

;; --- BigDecimal contagion + division (D-194 Unit B) ---
(deftest bigdec-arithmetic
  (testing "contagion: bigdec ⊗ {int,bigint,ratio} → bigdec; ⊗ float → float"
    (is (= "3.0M" (pr-str (* 1.5M 2))))
    (is (= "1.5M" (pr-str (+ 1 0.5M))))
    (is (= "3.0" (pr-str (* 1.5M 2.0))))
    (is (= "2.0M" (pr-str (+ 1.5M 1/2))))
    (is (= "4.5M" (pr-str (* 1.5M (bigint 3)))))
    (is (thrown? Throwable (+ 1.5M 1/3))))
  (testing "division is exact or throws; quot / rem / mod"
    (is (= "0.75M" (pr-str (/ 1.5M 2))))
    (is (= "3M" (pr-str (/ 6M 2))))
    (is (= "3.0M" (pr-str (quot 7.5M 2))))
    (is (= "0.10M" (pr-str (rem 1.50M 0.7M))))
    (is (= "1.5M" (pr-str (mod 7.5M 2))))
    (is (thrown? Throwable (/ 1M 3)))))

;; --- class? predicate (D-215): true only for a class object ---
(deftest class-predicate
  (is (= true (class? (class 5))))
  (is (= true (class? String)))
  (is (= false (class? 5)))
  (is (= false (class? nil)))
  (is (= false (class? "x"))))

;; --- D-337 / AD-044: callables / seqs / refs report a stable clj-faithful
;; simple class name, never the internal heap-tag name (was `fn_val` /
;; `lazy_seq` / `atom`). clj returns a generated/reify class for fns /
;; future / promise that cljw cannot mirror (AD-044); cljw is stable.
(deftest class-of-callables-and-refs
  (testing "functions"
    (is (= "Fn" (pr-str (class (fn [x] x)))))
    (is (= "Fn" (pr-str (class +))))
    (is (= "MultiFn" (.getName (class mm)))))
  (testing "seqs"
    (is (= "LazySeq" (pr-str (class (map inc [1])))))
    (is (= "LongRange" (pr-str (class (range 3)))))
    (is (= "ChunkedSeq" (pr-str (class (rest (cons 1 (range 3))))))))
  (testing "refs / boxes"
    (is (= "Future" (pr-str (class (future 1)))))
    (is (= "Agent" (pr-str (class (agent 0)))))
    (is (= "Atom" (pr-str (class (atom 0)))))
    (is (= "Ref" (pr-str (class (ref 0)))))
    (is (= "Volatile" (pr-str (class (volatile! 0)))))
    (is (= "Delay" (pr-str (class (delay 1)))))
    (is (= "Reduced" (pr-str (class (reduced 1)))))
    (is (= "TransientVector" (pr-str (class (transient []))))))
  (testing "class-level isa? still holds after the rename (isCallableClassName)"
    (is (= true (isa? (class +) clojure.lang.IFn)))))

;; --- ADR-0194: the five seq class symbols tools.reader's `inspect*`
;; dispatches on. A defmethod on a class symbol resolves it at ANALYZE time,
;; so these forms loading at all is the first assertion. LazySeq and Cons
;; name types cljw has, so they are native exact-tag classes and their
;; methods are reached. The three JVM inner seq classes name types cljw has
;; no values of (its vector seq is ArraySeq, its map seq is PersistentList),
;; so they resolve as OPAQUE class values whose `instance?` is uniformly
;; false and whose methods are never reached (AD-066 / AD-067).
(defmulti inspect-shape
  (fn [x] (cond (vector? x) :vector (map? x) :map :else (class x))))
(defmethod inspect-shape clojure.lang.PersistentVector$ChunkedSeq [_] :vec-seq)
(defmethod inspect-shape clojure.lang.PersistentArrayMap$Seq [_] :map-seq)
(defmethod inspect-shape clojure.lang.PersistentHashMap$NodeSeq [_] :map-seq)
(defmethod inspect-shape clojure.lang.Cons [_] :cons)
(defmethod inspect-shape clojure.lang.LazySeq [_] :lazy-seq)
(defmethod inspect-shape :default [_] :other)

(deftest native-seq-classes
  (testing "LazySeq resolves and is the class of a lazy seq"
    (is (= true (class? clojure.lang.LazySeq)))
    (is (= true (= clojure.lang.LazySeq (class (map inc [1])))))
    (is (= true (instance? clojure.lang.LazySeq (map inc [1]))))
    (is (= false (instance? clojure.lang.LazySeq [1])))
    (is (= false (instance? clojure.lang.LazySeq (range 3)))))
  (testing "Cons is a native exact-tag class, as on the JVM"
    (is (= true (class? clojure.lang.Cons)))
    (is (= true (= clojure.lang.Cons (class (cons 1 [2 3])))))
    (is (= true (instance? clojure.lang.Cons (cons 1 [2 3]))))))

(deftest opaque-jvm-seq-classes
  (testing "each resolves as a class value distinct from the others"
    (is (= true (class? clojure.lang.PersistentVector$ChunkedSeq)))
    (is (= true (class? clojure.lang.PersistentArrayMap$Seq)))
    (is (= true (class? clojure.lang.PersistentHashMap$NodeSeq)))
    (is (= false (= clojure.lang.Cons clojure.lang.PersistentVector$ChunkedSeq)))
    (is (= false (= clojure.lang.PersistentArrayMap$Seq
                    clojure.lang.PersistentHashMap$NodeSeq))))
  (testing "no cljw value is an instance of one (AD-066 / AD-067)"
    (is (= false (instance? clojure.lang.PersistentVector$ChunkedSeq (seq [1 2 3]))))
    (is (= false (instance? clojure.lang.PersistentArrayMap$Seq (seq {:a 1}))))
    (is (= false (instance? clojure.lang.PersistentHashMap$NodeSeq
                            (seq (zipmap (range 20) (range 20))))))))

(deftest inspect-multimethod-dispatches
  (testing "the native methods are reached"
    (is (= :lazy-seq (inspect-shape (map inc [1 2]))))
    (is (= :cons (inspect-shape (cons 1 [2 3])))))
  (testing "the opaque methods are dead: cljw seqs fall to :default (AD-066 / AD-067)"
    (is (= :other (inspect-shape (seq [1 2 3]))))
    (is (= :other (inspect-shape (seq (range 3)))))
    (is (= :other (inspect-shape (seq {:a 1}))))))
