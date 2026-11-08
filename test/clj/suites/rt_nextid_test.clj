;; The interop core.logic needs to load (`(require 'clojure.core.logic)`):
;;
;; - clojure.lang.RT/nextID returns monotonic ints from the same per-Runtime
;;   counter `gensym` uses (JVM RT.nextID backs gensym), so ids never collide
;;   with gensym suffixes.
;; - The `.` special form with a CLASS receiver is static access, as on the
;;   JVM: `(. Class member args…)` and `(. Class (member args…))` behave like
;;   `(Class/member args…)` for every class whose statics cljw models, and an
;;   unmodelled `clojure.lang.*` member keeps the AD-008 deferred rewrite.
;;   Surfaced by core.logic's `(. clojure.lang.RT (nextID))`.
;; - clojure.lang.IRecord is a recognised interface: every defrecord is an
;;   instance, and `(extend-protocol P clojure.lang.IRecord …)` serves every
;;   record without an impl of its own, ahead of an Object default.
;;   Surfaced by core.logic's IWalkTerm extension.
;; - clojure.lang.Fn (the AFunction marker every compiled fn implements)
;;   resolves as a class: `(extend-type clojure.lang.Fn …)` distributes over
;;   the fn tags, and `instance?` agrees. A MultiFn or an invocable keyword is
;;   IFn but NOT Fn, as in clj. Surfaced by core.logic's Inc stream.
;;
;; Every protocol, record and type gets its own name: the suite is one process.
(ns suites.rt-nextid-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.shell :refer [sh]]))

;; ---- clojure.lang.RT/nextID ----

(deftest rt-nextid
  (is (integer? (clojure.lang.RT/nextID)))
  (is (let [a (clojure.lang.RT/nextID) b (clojure.lang.RT/nextID)] (< a b)))
  (is (apply distinct? (repeatedly 100 #(clojure.lang.RT/nextID))))
  (testing "shares the gensym counter: a gensym between two ids sits strictly between them"
    (is (= [2 true]
           (let [a (clojure.lang.RT/nextID) g (gensym) b (clojure.lang.RT/nextID)]
             [(- b a) (= (str g) (str "G__" (inc a)))]))))
  (is (integer? (let [f clojure.lang.RT/nextID] (f))))
  (is (thrown-with-msg? Exception #"(?i)arity|wrong number"
                        (eval '(clojure.lang.RT/nextID 1)))))

;; ---- `.` with a class receiver ----

(defn dot-deferred [] (. clojure.lang.RT (baseLoader)))

(defn cljw-eval
  "Run `script` in a child cljw: feature_not_supported is not catchable
  in-process, so the deferred call is observed from outside."
  [script]
  (sh "zig-out/bin/cljw" "-e" script))

(deftest dot-static-class
  (is (= 3 (. Math abs -3)))
  (is (= 3 (. Math (abs -3))))
  (is (= 2 (. java.lang.Math (max 1 2))))
  (is (true? (. clojure.lang.Util (identical :a :a))))
  (is (= (. Math PI) Math/PI))
  (is (= (. Integer (MAX_VALUE)) Integer/MAX_VALUE))
  (is (integer? (. clojure.lang.RT (nextID))))
  (is (integer? (. clojure.lang.RT nextID)))
  (testing "a local named like a class is an instance receiver, never the class"
    (is (= 3 (let [Math "abc"] (. Math (length))))))
  (testing "instance receivers are untouched"
    (is (= "bc" (. "abcd" (substring 1 3)))))
  (testing "unmodelled clojure.lang.* member: the fn defines, the call errors loudly"
    (is (fn? dot-deferred))
    (let [{:keys [exit out err]}
          (cljw-eval "(do (defn f [] (. clojure.lang.RT (baseLoader))) (f))")]
      (is (not= 0 exit))
      (is (re-find #"clojure\.lang\.RT/baseLoader is not supported" (str out err))))))

;; ---- clojure.lang.IRecord ----

(defrecord IrR [a])
(deftype IrT [])

(defprotocol IrP (ir-f [x]))
(extend-protocol IrP clojure.lang.IRecord (ir-f [x] [:rec (:a x)]))

(defprotocol IrObj (ir-g [x]))
(extend-protocol IrObj
  Object (ir-g [x] :obj)
  clojure.lang.IRecord (ir-g [x] :rec))

(defprotocol IrOwn (ir-h [x]))
(extend-protocol IrOwn clojure.lang.IRecord (ir-h [x] :rec))
(defrecord IrOwnR [a] IrOwn (ir-h [x] :own))

(deftest irecord-extend
  (is (true? (instance? clojure.lang.IRecord (->IrR 1))))
  (is (false? (instance? clojure.lang.IRecord {:a 1})))
  (is (false? (instance? clojure.lang.IRecord (IrT.))))
  (is (= [:rec 1] (ir-f (->IrR 1))))
  (testing "an IRecord impl outranks an Object default"
    (is (= [:rec :obj :obj] [(ir-g (->IrR 1)) (ir-g {}) (ir-g 1)])))
  (testing "a record's own impl wins"
    (is (= :own (ir-h (->IrOwnR 1)))))
  (testing "a map is not a record"
    (is (thrown-with-msg? Exception #"No implementation of method 'ir-f'"
                          (ir-f {})))))

;; ---- clojure.lang.Fn ----

(defmulti fn-m identity)

(defprotocol FnP (fn-f [x]))
(extend-type clojure.lang.Fn FnP (fn-f [x] (x)))

(defprotocol FnQ (fn-q [x]))
(extend-type clojure.lang.Fn FnQ (fn-q [x] :fn))

(defprotocol FnA (fn-a [x]))
(defprotocol FnB (fn-b [x]))
(extend-type clojure.lang.Fn FnA (fn-a [x] 1) FnB (fn-b [x] 2))

(deftest fn-extend
  (is (true? (instance? clojure.lang.Fn (fn [] 1))))
  (is (true? (instance? clojure.lang.Fn inc)))
  (is (false? (instance? clojure.lang.Fn :k)))
  (is (false? (instance? clojure.lang.Fn fn-m)))
  (is (= :called (fn-f (fn [] :called))))
  (is (= :fn (fn-q inc)))
  (is (= [1 2] (let [g (fn [] 0)] [(fn-a g) (fn-b g)])))
  (testing "a keyword is IFn but not Fn"
    (is (thrown-with-msg? Exception #"No implementation of method 'fn-q'"
                          (fn-q :k)))))
