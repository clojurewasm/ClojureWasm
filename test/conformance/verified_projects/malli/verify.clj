(ns verify
  (:require [malli.core :as m]))
;; malli compiles a data schema to a validator/explainer. Exercise the paths a
;; consumer actually leans on: predicate + collection + map schemas, entry
;; parsing (the eager entry-parser array path), explain output, coercion-free
;; value walking, and the sequence-regex engine.
(defn -main [& _]
  (assert (true? (m/validate :int 1)))
  (assert (false? (m/validate :int "1")))
  (assert (true? (m/validate [:map [:x :int] [:y :string]] {:x 1 :y "a"})))
  (assert (false? (m/validate [:map [:x :int]] {:x "no"})))
  (assert (true? (m/validate [:vector :int] [1 2 3])))
  (assert (true? (m/validate [:maybe :int] nil)))
  (assert (true? (m/validate [:enum :a :b] :a)))
  (assert (= [:x] (-> (m/explain [:map [:x :int]] {:x "no"}) :errors first :in)))
  (assert (nil? (m/explain [:map [:x :int]] {:x 1})))
  (assert (= [:x :y] (m/explicit-keys (m/schema [:map [:x :int] [:y :string]]))))
  (assert (true? (m/validate [:cat :int :string] [1 "a"])))
  (assert (false? (m/validate [:cat :int :string] [1 2])))
  (println "OK malli — predicate/map/vector/enum schemas, explain, entry keys, sequence regex"))
