;; Upstream: clojure/test/clojure/test_clojure/metadata.clj
;; Upstream lines: 239
;; CLJW markers: 5

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Authors: Stuart Halloway, Frantisek Sodomka

;; CLJW: ns form simplified — removed test-helper require, added clojure.set
(ns clojure.test-clojure.metadata
  (:use clojure.test)
  (:require [clojure.set :as set]))

;; CLJW: public-vars-with-docstrings-have-added skipped — requires ns-publics,
;; mapcat over JVM namespaces (clojure.pprint, clojure.inspector, etc.), and
;; .sym interop accessor. Not applicable to our implementation.

;; CLJW: interaction-of-def-with-metadata skipped — requires eval-in-temp-ns
;; (JVM test helper using clojure.lang.RT/makeNamespace).

(deftest fns-preserve-metadata-on-maps
  (let [xm {:a 1 :b -7}
        x (with-meta {:foo 1 :bar 2} xm)
        ym {:c "foo"}
        y (with-meta {:baz 4 :guh x} ym)]

    (is (= xm (meta (:guh y))))
    (is (= xm (meta (reduce #(assoc %1 %2 (inc %2)) x (range 1000)))))
    (is (= xm (meta (-> x (dissoc :foo) (dissoc :bar)))))
    (let [z (assoc-in y [:guh :la] 18)]
      (is (= ym (meta z)))
      (is (= xm (meta (:guh z)))))
    (let [z (update-in y [:guh :bar] inc)]
      (is (= ym (meta z)))
      (is (= xm (meta (:guh z)))))
    (is (= xm (meta (get-in y [:guh]))))
    (is (= xm (meta (into x y))))
    (is (= ym (meta (into y x))))

    (is (= xm (meta (merge x y))))
    (is (= ym (meta (merge y x))))
    (is (= xm (meta (merge-with + x y))))
    (is (= ym (meta (merge-with + y x))))

    (is (= xm (meta (select-keys x [:bar]))))
    (is (= xm (meta (set/rename-keys x {:foo :new-foo}))))))

(deftest fns-preserve-metadata-on-vectors
  (let [xm {:a 1 :b -7}
        x (with-meta [1 2 3] xm)
        ym {:c "foo"}
        y (with-meta [4 x 6] ym)]

    (is (= xm (meta (y 1))))
    (is (= xm (meta (assoc x 1 "one"))))
    (is (= xm (meta (reduce #(conj %1 %2) x (range 1000)))))
    (is (= xm (meta (pop (pop (pop x))))))
    (let [z (assoc-in y [1 2] 18)]
      (is (= ym (meta z)))
      (is (= xm (meta (z 1)))))
    (let [z (update-in y [1 2] inc)]
      (is (= ym (meta z)))
      (is (= xm (meta (z 1)))))
    (is (= xm (meta (get-in y [1]))))
    (is (= xm (meta (into x y))))
    (is (= ym (meta (into y x))))

    (is (= xm (meta (replace {2 "two"} x))))
    (is (= [1 "two" 3] (replace {2 "two"} x)))))

(deftest fns-preserve-metadata-on-sets
  (let [xm {:a 1 :b -7}
        x (with-meta #{1 2 3} xm)
        ym {:c "foo"}
        y (with-meta #{4 x 6} ym)]

    (is (= xm (meta (y #{3 2 1}))))
    (is (= xm (meta (reduce #(conj %1 %2) x (range 1000)))))
    (is (= xm (meta (-> x (disj 1) (disj 2) (disj 3)))))
    (is (= xm (meta (into x y))))
    (is (= ym (meta (into y x))))

    (is (= xm (meta (set/select even? x))))
    (let [cow1m {:what "betsy cow"}
          cow1 (with-meta {:name "betsy" :id 33} cow1m)
          cow2m {:what "panda cow"}
          cow2 (with-meta {:name "panda" :id 34} cow2m)
          cowsm {:what "all the cows"}
          cows (with-meta #{cow1 cow2} cowsm)
          cow-names (set/project cows [:name])
          renamed (set/rename cows {:id :number})]
      (is (= cowsm (meta cow-names)))
      (is (= cow1m (meta (first (filter #(= "betsy" (:name %)) cow-names)))))
      (is (= cow2m (meta (first (filter #(= "panda" (:name %)) cow-names)))))
      (is (= cowsm (meta renamed)))
      (is (= cow1m (meta (first (filter #(= "betsy" (:name %)) renamed)))))
      (is (= cow2m (meta (first (filter #(= "panda" (:name %)) renamed))))))))

;; CLJW: defn-primitive-args skipped — requires eval-in-temp-ns and
;; JVM primitive type hints (^long, ^String).

;; CLJW-ADD: test runner invocation
(run-tests)
