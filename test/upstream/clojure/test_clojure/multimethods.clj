;; Upstream: clojure/test/clojure/test_clojure/multimethods.clj
;; Upstream lines: 272
;; CLJW markers: 11

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Frantisek Sodomka, Robert Lachlan

(ns clojure.test-clojure.multimethods
  ;; CLJW: replaced clojure.test-helper import with inline with-var-roots impl
  (:use clojure.test)
  (:require [clojure.set :as set]))

;; CLJW: inline with-var-roots from upstream clojure.test-helper
(defn- set-var-roots [maplike]
  (doseq [[v val] maplike]
    (alter-var-root v (fn [_] val))))

(defn- with-var-roots* [root-map f]
  (let [originals (doall (map (fn [[v _]] [v (deref v)]) root-map))]
    (set-var-roots root-map)
    (try
      (f)
      (finally
        (set-var-roots originals)))))

(defmacro with-var-roots [root-map & body]
  `(with-var-roots* ~root-map (fn [] ~@body)))

; http://clojure.org/multimethods

; defmulti
; defmethod
; remove-method
; prefer-method
; methods
; prefers

(defmacro for-all
  [& args]
  `(dorun (for ~@args)))

;; CLJW: hierarchy-tags uses instance? clojure.lang.Named — JVM interop
;; Replaced with keyword?/symbol? check
(defn hierarchy-tags
  "Return all tags in a derivation hierarchy"
  [h]
  (set/select
   #(or (keyword? %) (symbol? %))
   (reduce into #{} (map keys (vals h)))))

(defn transitive-closure
  "Return all objects reachable by calling f starting with o,
   not including o itself. f should return a collection."
  [o f]
  (loop [results #{}
         more #{o}]
    (let [new-objects (set/difference more results)]
      (if (seq new-objects)
        (recur (set/union results more) (reduce into #{} (map f new-objects)))
        (disj results o)))))

;; CLJW: tag-descendants uses instance? clojure.lang.Named — replaced
(defn tag-descendants
  "Set of descedants which are tags (i.e. Named)."
  [& args]
  (set/select
   #(or (keyword? %) (symbol? %))
   (or (apply descendants args) #{})))

(defn assert-valid-hierarchy
  [h]
  (let [tags (hierarchy-tags h)]
    (testing "ancestors are the transitive closure of parents"
      (for-all [tag tags]
               (is (= (transitive-closure tag #(parents h %))
                      (or (ancestors h tag) #{})))))
    (testing "ancestors are transitive"
      (for-all [tag tags]
               (is (= (transitive-closure tag #(ancestors h %))
                      (or (ancestors h tag) #{})))))
    (testing "tag descendants are transitive"
      (for-all [tag tags]
               (is (= (transitive-closure tag #(tag-descendants h %))
                      (or (tag-descendants h tag) #{})))))
    (testing "a tag isa? all of its parents"
      (for-all [tag tags
                :let [parents (parents h tag)]
                parent parents]
               (is (isa? h tag parent))))
    (testing "a tag isa? all of its ancestors"
      (for-all [tag tags
                :let [ancestors (ancestors h tag)]
                ancestor ancestors]
               (is (isa? h tag ancestor))))
    (testing "all my descendants have me as an ancestor"
      (for-all [tag tags
                :let [descendants (descendants h tag)]
                descendant descendants]
               (is (isa? h descendant tag))))
    (testing "there are no cycles in parents"
      (for-all [tag tags]
               (is (not (contains? (transitive-closure tag #(parents h %)) tag)))))
    (testing "there are no cycles in descendants"
      (for-all [tag tags]
               (is (not (contains? (descendants h tag) tag)))))))

(def family
  (reduce #(apply derive (cons %1 %2)) (make-hierarchy)
          [[::parent-1 ::ancestor-1]
           [::parent-1 ::ancestor-2]
           [::parent-2 ::ancestor-2]
           [::child ::parent-2]
           [::child ::parent-1]]))

(deftest cycles-are-forbidden
  (testing "a tag cannot be its own parent"
    ;; CLJW: thrown-with-msg? not supported; use thrown?
    (is (thrown? Exception
                 (derive family ::child ::child))))
  (testing "a tag cannot be its own ancestor"
    ;; CLJW: thrown-with-msg? not supported; use thrown?
    (is (thrown? Exception
                 (derive family ::ancestor-1 ::child)))))

(deftest using-diamond-inheritance
  (let [diamond (reduce #(apply derive (cons %1 %2)) (make-hierarchy)
                        [[::mammal ::animal]
                         [::bird ::animal]
                         [::griffin ::mammal]
                         [::griffin ::bird]])
        bird-no-more (underive diamond ::griffin ::bird)]
    (assert-valid-hierarchy diamond)
    (assert-valid-hierarchy bird-no-more)
    (testing "a griffin is a mammal, indirectly through mammal and bird"
      (is (isa? diamond ::griffin ::animal)))
    (testing "a griffin is a bird"
      (is (isa? diamond ::griffin ::bird)))
    (testing "after underive, griffin is no longer a bird"
      (is (not (isa? bird-no-more ::griffin ::bird))))
    (testing "but it is still an animal, via mammal"
      (is (isa? bird-no-more ::griffin ::animal)))))

;; CLJW: JVM interop — Java class hierarchy derivation
;; (deftest derivation-world-bridges-to-java-inheritance ...)

(deftest global-hierarchy-test
  (with-var-roots {#'clojure.core/global-hierarchy (make-hierarchy)}
    (assert-valid-hierarchy @#'clojure.core/global-hierarchy)
    (testing "when you add some derivations..."
      (derive ::lion ::cat)
      (derive ::manx ::cat)
      (assert-valid-hierarchy @#'clojure.core/global-hierarchy))
    (testing "...isa? sees the derivations"
      (is (isa? ::lion ::cat))
      (is (not (isa? ::cat ::lion))))
    (testing "... you can traverse the derivations"
      (is (= #{::manx ::lion} (descendants ::cat)))
      (is (= #{::cat} (parents ::manx)))
      (is (= #{::cat} (ancestors ::manx))))
    (testing "then, remove a derivation..."
      (underive ::manx ::cat))
    (testing "... traversals update accordingly"
      (is (= #{::lion} (descendants ::cat)))
      (is (nil? (parents ::manx)))
      (is (nil? (ancestors ::manx))))))

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

;; CLJW: JVM interop — java.util.Map, String class dispatch
;; (deftest isA-multimethod-test ...)

(deftest preferences-multimethod-test
  (testing "Multiple method match dispatch error is caught"
    ;; Example from the multimethod docs.
    (derive ::rect ::shape)
    (defmulti bar (fn [x y] [x y]))
    (defmethod bar [::rect ::shape] [x y] :rect-shape)
    (defmethod bar [::shape ::rect] [x y] :shape-rect)
    ;; CLJW: thrown? Exception instead of java.lang.IllegalArgumentException
    (is (thrown? Exception
                 (bar ::rect ::rect))))
  (testing "The prefers method returns empty table w/ no prefs"
    (is (= {} (prefers bar))))
  (testing "Adding a preference to resolve it dispatches correctly"
    (prefer-method bar [::rect ::shape] [::shape ::rect])
    (is (= :rect-shape (bar ::rect ::rect))))
  (testing "The prefers method now returns the correct table"
    (is (= {[::rect ::shape] #{[::shape ::rect]}} (prefers bar)))))

(deftest indirect-preferences-mulitmethod-test
  (testing "Using global hierarchy"
    (derive ::parent-1 ::grandparent-1)
    (derive ::parent-2 ::grandparent-2)
    (derive ::child-mm ::parent-1)
    (derive ::child-mm ::parent-2)
    (testing "x should be preferred over y if x is preferred over an ancestor of y"
      (defmulti indirect-1 keyword)
      (prefer-method indirect-1 ::parent-1 ::grandparent-2)
      (defmethod indirect-1 ::parent-1 [_] ::parent-1)
      (defmethod indirect-1 ::parent-2 [_] ::parent-2)
      (is (= ::parent-1 (indirect-1 ::child-mm))))
    (testing "x should be preferred over y if an ancestor of x is preferred over y"
      (defmulti indirect-2 keyword)
      (prefer-method indirect-2 ::grandparent-1 ::parent-2)
      (defmethod indirect-2 ::parent-1 [_] ::parent-1)
      (defmethod indirect-2 ::parent-2 [_] ::parent-2)
      (is (= ::parent-1 (indirect-2 ::child-mm)))))
  (testing "Using custom hierarchy"
    (def local-h (-> (make-hierarchy)
                     (derive :parent-1 :grandparent-1)
                     (derive :parent-2 :grandparent-2)
                     (derive :child-mm :parent-1)
                     (derive :child-mm :parent-2)))
    (testing "x should be preferred over y if x is preferred over an ancestor of y"
      (defmulti indirect-3 keyword :hierarchy #'local-h)
      (prefer-method indirect-3 :parent-1 :grandparent-2)
      (defmethod indirect-3 :parent-1 [_] :parent-1)
      (defmethod indirect-3 :parent-2 [_] :parent-2)
      (is (= :parent-1 (indirect-3 :child-mm))))
    (testing "x should be preferred over y if an ancestor of x is preferred over y"
      (defmulti indirect-4 keyword :hierarchy #'local-h)
      (prefer-method indirect-4 :grandparent-1 :parent-2)
      (defmethod indirect-4 :parent-1 [_] :parent-1)
      (defmethod indirect-4 :parent-2 [_] :parent-2)
      (is (= :parent-1 (indirect-4 :child-mm))))))

(deftest remove-all-methods-test
  (testing "Core function remove-all-methods works"
    (defmulti simple1 identity)
    (defmethod simple1 :a [x] :a)
    (defmethod simple1 :b [x] :b)
    (is (= {} (methods (remove-all-methods simple1))))))

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

(deftest get-method-test
  (testing "Core function get-method works"
    (defmulti simple3 identity)
    (defmethod simple3 :a [x] :a)
    (defmethod simple3 :b [x] :b)
    (is (fn? (get-method simple3 :a)))
    (is (= :a ((get-method simple3 :a) 1)))
    (is (fn? (get-method simple3 :b)))
    (is (= :b ((get-method simple3 :b) 1)))
    (is (nil? (get-method simple3 :c)))))

;; CLJW-ADD: test runner invocation
(run-tests)
