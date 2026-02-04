;; Ported from clojure/test_clojure/multimethods.clj
;; SKIP: hierarchy tests (make-hierarchy, derive, underive, parents, ancestors,
;;       descendants — not implemented, F82)
;; SKIP: Java class dispatch (isA-multimethod-test — JVM-specific)
;; SKIP: prefer-method, prefers (not implemented, F83)
;; SKIP: global-hierarchy-test (needs derive/underive)
;; SKIP: indirect-preferences-multimethod-test (needs derive + prefer-method)
;; NOTE: defmulti/defmethod are TreeWalk only (D28, F13 for VM opcodes)

(ns clojure.test-clojure.multimethods
  (:use clojure.test))

;; === basic-multimethod-test ===

(deftest basic-multimethod-test
  (testing "Check basic dispatch"
    (defmulti too-simple identity)
    (defmethod too-simple :a [x] :a)
    (defmethod too-simple :b [x] :b)
    (defmethod too-simple :default [x] :default)
    (is (= :a (too-simple :a)))
    (is (= :b (too-simple :b)))
    (is (= :default (too-simple :c))))
  (testing "Remove a method works"
    (remove-method too-simple :a)
    (is (= :default (too-simple :a))))
  (testing "Add another method works"
    (defmethod too-simple :d [x] :d)
    (is (= :d (too-simple :d)))))

;; === remove-all-methods-test ===

(deftest remove-all-methods-test
  (testing "Core function remove-all-methods works"
    (defmulti simple1 identity)
    (defmethod simple1 :a [x] :a)
    (defmethod simple1 :b [x] :b)
    (is (= {} (methods (remove-all-methods simple1))))))

;; === methods-test ===

(deftest methods-test
  (testing "Core function methods works"
    (defmulti simple2 identity)
    (defmethod simple2 :a [x] :a)
    (defmethod simple2 :b [x] :b)
    (is (= #{:a :b} (into #{} (keys (methods simple2)))))
    (is (= :a ((:a (methods simple2)) 1)))
    (defmethod simple2 :c [x] :c)
    (is (= #{:a :b :c} (into #{} (keys (methods simple2)))))
    (remove-method simple2 :a)
    (is (= #{:b :c} (into #{} (keys (methods simple2)))))))

;; === get-method-test ===

(deftest get-method-test
  (testing "Core function get-method works"
    (defmulti simple3 identity)
    (defmethod simple3 :a [x] :a)
    (defmethod simple3 :b [x] :b)
    ;; SKIP: (fn? (get-method ...)) — fn? returns false for fn_val (F84)
    (is (= :a ((get-method simple3 :a) 1)))
    (is (= :b ((get-method simple3 :b) 1)))
    (is (nil? (get-method simple3 :c)))))

;; === Custom dispatch function tests ===

(deftest keyword-dispatch-test
  (testing "Dispatch on keyword extracted from map"
    (defmulti area :shape)
    (defmethod area :circle [x] (* 3 (:radius x) (:radius x)))
    (defmethod area :rect [x] (* (:width x) (:height x)))
    (is (= 75 (area {:shape :circle :radius 5})))
    (is (= 12 (area {:shape :rect :width 3 :height 4})))))

(deftest default-method-test
  (testing "Default method is invoked for unmatched dispatch"
    (defmulti greet identity)
    (defmethod greet :en [_] "hello")
    (defmethod greet :default [_] "hi")
    (is (= "hello" (greet :en)))
    (is (= "hi" (greet :fr)))
    (is (= "hi" (greet :de)))))

(deftest multi-arg-dispatch-test
  (testing "Dispatch on first argument"
    (defmulti op (fn [tag & args] tag))
    (defmethod op :add [_ a b] (+ a b))
    (defmethod op :mul [_ a b] (* a b))
    (is (= 5 (op :add 2 3)))
    (is (= 6 (op :mul 2 3)))))

(deftest string-dispatch-test
  (testing "Dispatch on string value"
    (defmulti handle-event (fn [evt] (:type evt)))
    (defmethod handle-event "click" [evt] (str "clicked " (:target evt)))
    (defmethod handle-event "hover" [evt] (str "hovered " (:target evt)))
    (defmethod handle-event :default [evt] "unknown event")
    (is (= "clicked button" (handle-event {:type "click" :target "button"})))
    (is (= "hovered link" (handle-event {:type "hover" :target "link"})))
    (is (= "unknown event" (handle-event {:type "scroll"})))))

(deftest integer-dispatch-test
  (testing "Dispatch on integer value"
    (defmulti classify-num identity)
    (defmethod classify-num 0 [_] :zero)
    (defmethod classify-num 1 [_] :one)
    (defmethod classify-num :default [_] :other)
    (is (= :zero (classify-num 0)))
    (is (= :one (classify-num 1)))
    (is (= :other (classify-num 42)))))

;; Run tests
(run-tests)
